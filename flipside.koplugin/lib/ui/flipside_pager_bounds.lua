-- Constrain only FlipSide's native Menu pagination footer to the screen width.
-- No review, statistics, sync, or global KOReader widget changes.
local Screen = require("device").screen
local Size = require("ui/size")

local M = {}

function M.fit(menu)
    local group = menu and menu.page_info
    local spacer = menu and menu.page_info_spacer
    local page = menu and menu.page_info_text
    local arrows = menu and {
        menu.page_info_first_chev, menu.page_info_left_chev,
        menu.page_info_right_chev, menu.page_info_last_chev,
    }
    if not group or not spacer or not page or not arrows
        or not arrows[1] or not arrows[2] or not arrows[3] or not arrows[4] then
        return
    end
    local w = menu.inner_dimen and menu.inner_dimen.w
        or menu.dimen and menu.dimen.w or Screen:getWidth()
    if not w or w <= 0 then return end
    local margin = math.max(2, math.min(Screen:scaleBySize(6), math.floor(w * 0.02)))
    local usable = math.max(1, w - 2 * margin)
    local page_w = page:getSize().w
    local arrow_sum = 0
    for _, button in ipairs(arrows) do
        button._flipside_native_pager_icon = button._flipside_native_pager_icon or button.icon_width
        -- Budget against the ORIGINAL sizes so later updates do not alternate
        -- between shrinking and restoring icons at the same screen size.
        local pad = 2 * (button.padding_h or button.padding or Size.padding.button)
            + 2 * (button.margin or 0) + 2 * (button.bordersize or 0)
        arrow_sum = arrow_sum + button._flipside_native_pager_icon + pad
    end
    local full_gap = Screen:scaleBySize(32) -- The original KOReader Menu gap.
    local space = math.min(full_gap, math.max(0, math.floor((usable - page_w - arrow_sum) / 4)))

    -- Prefer changing empty gaps: leave native chevrons and touch sizes alone
    -- when spacing alone can prevent side clipping at the user's selected DPI.
    local min_gap = math.max(1, math.min(Screen:scaleBySize(4), math.floor(w * 0.01)))
    if space < min_gap then
        space = min_gap
        local icon_budget = math.floor((usable - page_w - 4 * space) / 4)
        for _, button in ipairs(arrows) do
            local horizontal_pad = 2 * (button.padding_h or button.padding or Size.padding.button)
                + 2 * (button.margin or 0) + 2 * (button.bordersize or 0)
            local icon_size = math.max(1, math.min(button._flipside_native_pager_icon,
                icon_budget - horizontal_pad))
            if button.icon_width ~= icon_size then
                local was_hidden = button.hidden
                if button.label_widget and button.label_widget.free then
                    button.label_widget:free()
                end
                button.icon_width = icon_size
                button.icon_height = icon_size
                button:init() -- preserves original callback, enabled flag, and icon name
                if was_hidden then
                    button.label_widget.hide = true
                    button.frame.orig_background = button.frame.background
                    button.frame.background = nil
                end
            end
        end
    else
        -- Restore native icon sizes if the screen later gets more room.
        for _, button in ipairs(arrows) do
            local icon_size = button._flipside_native_pager_icon
            if icon_size and button.icon_width ~= icon_size then
                local was_hidden = button.hidden
                if button.label_widget and button.label_widget.free then
                    button.label_widget:free()
                end
                button.icon_width = icon_size
                button.icon_height = icon_size
                button:init()
                if was_hidden then
                    button.label_widget.hide = true
                    button.frame.orig_background = button.frame.background
                    button.frame.background = nil
                end
            end
        end
    end

    -- The page label can grow on later pages (e.g. Page 100 of 120).
    -- Reserve its width every time without changing its font or behavior.
    local final_sum = 0
    for _, button in ipairs(arrows) do final_sum = final_sum + button:getSize().w end
    space = math.max(0, math.min(full_gap,
        math.floor((usable - page:getSize().w - final_sum) / 4)))
    spacer.width = space -- KOReader reuses the same spacer in all four slots.
    group:resetLayout() -- KOReader HorizontalGroup caches previous dimensions.
end

return M
