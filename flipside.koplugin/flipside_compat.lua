-- FlipSide-specific compatibility bridge for integrated former patches.
-- Not KOReader's global userpatch. Not allowed to target any other plugin.
local logger = require("logger")
local M = { callbacks = {}, callback_roles = {}, applied = false }
function M.getUpValue(fn, target)
    if type(fn) == "table" and type(fn.f) == "function" then fn = fn.f end
    if type(fn) ~= "function" then return nil end
    for i = 1, 200 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == target then return value end
    end
end
function M.registerPatchPluginFunc(plugin_name, fn, role)
    -- Only callbacks explicitly targeting FlipSide are accepted; no legacy
    -- Vocabulary Builder plugin name can be used to target another plugin.
    if plugin_name ~= "flipside" then
        return false
    end
    if type(fn) ~= "function" then return false end
    local index = #M.callbacks + 1
    M.callbacks[index] = fn
    -- Optional metadata only: other plugin integrations keep their old API.
    if role == "learning_audit" or role == "activity_stats" then
        M.callback_roles[index] = role
    else
        M.callback_roles[index] = nil
    end
    return true
end
function M.applyToFlipSide(plugin)
    if M.applied then return end
    M.applied = true
    for n, fn in ipairs(M.callbacks) do
        local ok, err = pcall(fn, plugin)
        if not ok then
            logger.warn("FlipSide integrated module", n, "failed:", err)
            -- A require() can succeed while its deferred audit hook fails.
            -- Keep other hooks running and make this loss of statistics visible.
            local role = M.callback_roles[n]
            if role == "learning_audit" or role == "activity_stats" then
                if type(plugin) == "table" then
                    plugin._flipside_audit_load_failed = true
                end
                local diag_ok, Diag = pcall(require, "flipside_diagnostics")
                if diag_ok and type(Diag) == "table"
                        and type(Diag.report) == "function" then
                    pcall(Diag.report, "ERROR", "LEARNING_AUDIT_ERROR",
                        {stage = "hook_apply", component = role}, err)
                end
            end
        end
    end
end
return M
