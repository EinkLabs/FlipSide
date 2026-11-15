-- FlipSide Kindle/e-ink sleep diagnostics v2.
-- Passive observer. Does not change UIManager refresh semantics or SRS data.
-- Traces the small number of lifecycle transitions and suspect draw requests.
local Trace = {}
local Diag = require("flipside_diagnostics")
local installed = false
local is_observing = false
local suspicious = 0
local lifecycle_id = 0
local MAX_DRAW_LOGS = 14

local function safeName(widget)
    if widget == nil then return "none" end
    if widget == "all" then return "all" end
    local kind = type(widget)
    if kind ~= "table" then return kind end
    local name = rawget(widget, "name") or widget.name
    if type(name) == "string" and #name <= 50
            and name:match("^[%w_%-]+$") then return name end
    -- Never serialize widget contents: they may contain book text.
    return "widget"
end

local function currentState(ui, device, current)
    local windows = ui._window_stack
    local summary = {top="none", stack="none", depth=0,
        dialogs=0, flash_visible=false}
    if type(windows) == "table" then
        summary.depth = #windows
        local top = windows[#windows]
        summary.top = top and safeName(top.widget) or "none"
        local names = {}
        for i = math.max(1, #windows - 5), #windows do
            local row = windows[i]
            if row then names[#names+1] = safeName(row.widget) end
        end
        summary.stack = table.concat(names, "/")
        for _, row in ipairs(windows) do
            local w = row.widget
            if w == current then summary.flash_visible = true end
            if w and current and (w == current._today_dialog
                    or w == current._intensive_dialog) then
                summary.dialogs = summary.dialogs + 1
            end
        end
    end
    summary.screen_saver = device.screen_saver_mode and true or false
    summary.sleep_paused = current and current._sleep_paused and true or false
    summary.pending_clock = current and current._clock_action ~= nil or false
    summary.pending_due = current and current._due_watch_action ~= nil or false
    summary.pending_resume = current and current._resume_action ~= nil or false
    summary.pending_recover = current and current._recover_action ~= nil or false
    summary.pending_reload = current and current._reload_pending and true or false
    summary.phase = current and current.state or "not_open"
    summary.view = current and current.retry_round and "cram"
        or current and current.practice and "practice" or "review"
    return summary
end

local function formatState(data)
    local parts = {}
    for _, key in ipairs({"top","stack","depth","dialogs","flash_visible",
        "screen_saver","sleep_paused","pending_clock","pending_due",
        "pending_resume","pending_recover","pending_reload","phase","view"}) do
        parts[#parts+1] = key .. "=" .. tostring(data[key])
    end
    return table.concat(parts, "; ")
end

function Trace.transition(label, ui, device, current)
    -- A few short disk writes only on actual sleep/wake transitions.
    lifecycle_id = lifecycle_id + 1
    if label == "suspend" or label == "saver_seen" then suspicious = 0 end
    local state = currentState(ui, device, current)
    Diag.sleepEvent("LIFECYCLE_" .. label:upper(), formatState(state),
        "trace_id=" .. lifecycle_id)
    Diag.event("sleep", label, {stage=label, pending=state.depth,
        status=state.screen_saver and "saver" or "awake"})
end

function Trace.blocked(operation, ui, device, current)
    if suspicious >= MAX_DRAW_LOGS then return end
    suspicious = suspicious + 1
    local state = currentState(ui, device, current)
    local source = debug and debug.traceback and debug.traceback("", 3)
        or "Lua stack unavailable"
    Diag.sleepEvent("FLIPSIDE_DRAW_BLOCKED", formatState(state),
        "operation=" .. tostring(operation) .. "\n" .. source)
end

function Trace.install(ui, device, getCurrent)
    if installed then return true end
    if type(ui) ~= "table" or type(ui.setDirty) ~= "function"
            or type(getCurrent) ~= "function" then return false end
    local native_setDirty = ui.setDirty
    local function observing_setDirty(self, widget, mode, ...)
        -- No extra work in normal reading. The real KOReader call always runs.
        if not is_observing and device.screen_saver_mode then
            is_observing = true
            suspicious = 0
        end
        if is_observing then
            local flash = getCurrent()
            local sleeping = device.screen_saver_mode
                or (flash and flash._sleep_paused)
            if sleeping and suspicious < MAX_DRAW_LOGS then
                local origin = debug and debug.traceback
                    and debug.traceback("", 2) or "Lua stack unavailable"
                -- Ignore this observer's OWN stack frame; otherwise every
                -- KOReader/native refresh would be mislabeled as FlipSide.
                local plugin_caller = false
                for line in origin:gmatch("[^\n]+") do
                    local module_name = line:match("([%w_]+%.lua):%d+")
                    if module_name and module_name:match("^flipside_")
                            and module_name ~= "flipside_sleep_trace.lua"
                            and module_name ~= "flipside_diagnostics.lua" then
                        plugin_caller = true
                        break
                    end
                end
                local from_flipside = widget == flash
                    or (flash and (widget == flash._today_dialog
                        or widget == flash._intensive_dialog))
                    or plugin_caller
                local state = currentState(ui, device, flash)
                local code = from_flipside and "FLIPSIDE_DIRTY_WHILE_SLEEP"
                    or "OTHER_DIRTY_WHILE_SLEEP"
                suspicious = suspicious + 1
                Diag.sleepEvent(code, formatState(state),
                    "target=" .. safeName(widget)
                    .. "; refresh=" .. (type(mode) == "string" and mode or type(mode))
                    .. "\n" .. origin)
            end
        end
        return native_setDirty(self, widget, mode, ...)
    end
    ui.setDirty = observing_setDirty
    installed = true
    return true
end

function Trace.windowShown(ui, device, current, widget)
    if suspicious >= MAX_DRAW_LOGS then return end
    suspicious = suspicious + 1
    local state = currentState(ui, device, current)
    local name = safeName(widget)
    local explicitly_owned = current and (widget == current
        or widget == current._today_dialog or widget == current._intensive_dialog)
        or type(widget) == "table" and widget._flipside_settings_popup
    local origin = debug and debug.traceback and debug.traceback("", 3)
        or "Lua stack unavailable"
    Diag.sleepEvent(explicitly_owned and "FLIPSIDE_WINDOW_SHOWN_DURING_SLEEP"
        or "WINDOW_SHOWN_DURING_SLEEP", formatState(state),
        "window=" .. name .. "\n" .. origin)
end

function Trace.watch(enable)
    is_observing = enable and true or false
    if enable then suspicious = 0 end
end

-- No global Lua error handler and no monkey-patch of the e-ink screen driver.
-- In particular, never swallow/replace a native KOReader refresh.
return Trace
