-- FlipSide is a standalone plugin. No automatic migration or copying from
-- KOReader's native Vocabulary Builder is performed on startup. The old
-- private FlipSide data are preserved. Manual, one-way, incremental import
-- remains available exclusively in Aa -> Import from Vocabulary Builder.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local M = {}
function M.ensure()
    local private = DataStorage:getSettingsDir() .. "/flipside"
    local kind = lfs.attributes(private, "mode")
    if kind == "directory" then return true end
    if kind then error("FlipSide private path is not a directory: " .. private) end
    local ok, err = lfs.mkdir(private)
    if not ok and lfs.attributes(private, "mode") ~= "directory" then
        error("Cannot create FlipSide private settings directory: " .. tostring(err))
    end
    return true
end
return M
