-- FlipSide graphical-menu beta: preserves compact sync actions and original Cloud sync.
-- The module load is guarded: if a private component errors, KOReader still
-- loads a minimal FlipSide entry with an actionable error message.
local logger = require("logger")
local Diag = require("flipside_diagnostics")

local function loadFlipSide()
    Diag.event("startup", "load_modules")
    require("flipside_migrate").ensure()
    local Engine = require("flipside_engine")
    local hooks = require("flipside_compat")
    require("flipside_full_sentence")
    require("flipside_virtual_filters")
    -- Learning Analysis is optional for startup, but never silently omitted.
    -- If it fails during require(), remove only callbacks it registered in
    -- this incomplete load; the working flashcard engine must still open.
    local prior_callbacks = #hooks.callbacks
    local audit_ok, audit_err = pcall(require, "flipside_learning_audit")
    if not audit_ok then
        for i = #hooks.callbacks, prior_callbacks + 1, -1 do
            hooks.callbacks[i] = nil
            hooks.callback_roles[i] = nil
        end
        logger.warn("FlipSide: Learning Analysis module failed to load:", audit_err)
        pcall(Diag.report, "ERROR", "LEARNING_AUDIT_ERROR",
            {stage="module_load"}, audit_err)
        Engine._flipside_audit_load_failed = true
    end
    require("flipside_dictionary_locks")
    require("flipside_saved_meanings")
    require("flipside_flashcards")
    hooks.applyToFlipSide(Engine)
    return Engine
end

local ok, result = xpcall(loadFlipSide, function(err)
    Diag.report("CRITICAL", "PLUGIN_LOAD_FAILED", {stage="module_load"}, err)
    return err
end)
if ok then
    logger.info("FlipSide v0.1.6: internal modules loaded")
    return result
end

-- Never show the legacy list when an integrated component fails.
-- Present the actual error in the UI instead of silently disappearing.
local failure = tostring(result)
logger.err("FlipSide v0.1.6 load failed: " .. failure)
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Fallback = WidgetContainer:extend{ name = "flipside" }
function Fallback:init()
    self.ui.menu:registerToMainMenu(self)
end
function Fallback:addToMainMenu(menu_items)
    menu_items.flipside = {
        text = "FlipSide (erro ao carregar)",
        sorting_hint = "search",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = "FlipSide não conseguiu carregar um módulo.\n\n" .. failure ..
                    "\n\nConfira koreader/crash.log e koreader/verbose.log.",
            })
        end,
    }
end
return Fallback
