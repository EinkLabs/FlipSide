-- FlipSide generated monochrome SVG icon storage.
-- Runtime icons belong in private settings/cache, never in the KOReader root.
-- Does not move/remove any existing user files or modify plugin assets.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local M = {}
local root = DataStorage:getSettingsDir() .. "/flipside"
local icon_dir = root .. "/cache/icons"

local function ensure_directory(dir)
    local mode = lfs.attributes(dir, "mode")
    if mode == "directory" then return true end
    if mode ~= nil then return false end
    local ok = lfs.mkdir(dir)
    return ok or lfs.attributes(dir, "mode") == "directory"
end

function M.path(name)
    -- Filenames are internal constants or a safe decimal badge; no arbitrary paths.
    if type(name) ~= "string" or not name:match("^[%w_%-]+%.svg$") then
        error("Invalid FlipSide icon name")
    end
    if not (ensure_directory(root) and ensure_directory(root .. "/cache")
            and ensure_directory(icon_dir)) then
        -- Existing caller handles a failed io.open and uses its prior fallback.
        logger.warn("FlipSide: cannot create private icon cache directory:", icon_dir)
    end
    return icon_dir .. "/" .. name
end

return M
