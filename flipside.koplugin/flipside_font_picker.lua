-- FlipSide: font-family chooser for personal KOReader fonts on Android/Kindle.
-- Show one entry per FreeType FAMILY, not one entry per Regular/Bold/Italic
-- file. Both user fonts roots are scanned, but never Kindle system directories.
-- This module does not copy/move fonts or touch vocabulary data.
local Font = require("ui/font")
local FontList = require("fontlist")
local DataStorage = require("datastorage")
local FT = require("ffi/freetype")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")

local M = {}
local EXTENSIONS = { ttf=true, otf=true, ttc=true, cff=true, woff=true, woff2=true }
-- KOReader is started from its APK's *application* directory on Android.
-- In that context, ./fonts refers to bundled fonts (Nimbus, Noto, etc.), NOT
-- the user's /storage/emulated/0/koreader/fonts directory. Always start from
-- the same external data directory that KOReader itself uses.
local personal_fonts = DataStorage:getDataDir() .. "/fonts"
local android_fonts
local android_ok, android = pcall(require, "android")
if android_ok and android and type(android.getExternalStoragePath) == "function" then
    local path_ok, external = pcall(android.getExternalStoragePath)
    if path_ok and type(external) == "string" and external ~= "" then
        android_fonts = external .. "/Fonts"
    end
end

local USER_DIRS = {
    -- Personal folder shown by Android file managers as Main storage > koreader > fonts.
    { key="personal", path=personal_fonts },
    -- Kindle user fonts: retain support for existing E-Ink installations.
    { key="root", path="/mnt/us/fonts" },
    -- Android's optional shared fonts folder.
    { key="android-fonts", path=android_fonts },
    { key="koreader-us", path="/mnt/us/koreader/fonts" },
    { key="linkfonts", path="/mnt/us/linkfonts/fonts" },
    { key="data-fonts", path="/mnt/us/koreader/data/fonts" },
}
-- Keep old IDs readable even though bundled ./fonts are no longer enumerated.
-- This avoids silently losing the selection when upgrading the plugin.
local LEGACY_DIRS = { koreader="./fonts" }
local BY_KEY = {}
for _, dir in ipairs(USER_DIRS) do
    if type(dir.path) == "string" and dir.path ~= "" then
        BY_KEY[dir.key] = dir.path
    end
end
for key, path in pairs(LEGACY_DIRS) do BY_KEY[key] = path end
local name_cache = {}

function M.root()
    -- The personal KOReader directory is authoritative on Android.
    -- Never silently fall back to bundled ./fonts.
    return personal_fonts
end

local function parseId(id)
    if type(id) ~= "string" then return nil end
    local key, rel = id:match("^([%w%-]+):(.+)$")
    if not key or not BY_KEY[key] then return nil end
    if rel:sub(1, 1) == "/" or rel:find("\\", 1, true) or rel:find("%z") then
        return nil
    end
    for part in rel:gmatch("[^/]+") do
        if part == "." or part == ".." then return nil end
    end
    local ext = rel:lower():match("%.([^.]+)$")
    if not (ext and EXTENSIONS[ext]) then return nil end
    return key, rel
end

-- Preserve the old public name used by flipside_flashcards.lua.
function M.isRootId(id)
    return parseId(id) ~= nil
end

-- The former selector saved root:<filename> even when /mnt/us/fonts did not
-- exist and it was scanning ./fonts. Try the old fallback for those settings.
function M.resolve(id)
    local key, rel = parseId(id)
    if not key then return nil end
    local path = BY_KEY[key] .. "/" .. rel
    if lfs.attributes(path, "mode") == "file" then return path end
    if key == "root" then
        for _, old_dir in ipairs({"./fonts", "/mnt/us/koreader/fonts"}) do
            local old_path = old_dir .. "/" .. rel
            if lfs.attributes(old_path, "mode") == "file" then return old_path end
        end
    end
    return nil
end

-- The KOReader build running on some Android installations does not open
-- absolute font filenames in ui/font.lua directly: it prepends ./fonts/ and
-- retries only against paths already registered in FontList. A selected
-- external file must therefore be registered before the FIRST attempt to
-- construct its FontFaceObj. Keep this confined to user-picked files.
-- Never return an untested path to Button/TextWidget/our menu font override:
-- Font:getFace may return nil (rather than throw), causing a later crash in
-- Font:getAdjustedFace on the next automatic FlipSide opening.
local runtime_font_cache = {}
function M.renderable(id)
    local path = M.resolve(id)
    if not path then return nil end
    local cached = runtime_font_cache[id]
    if cached and cached.path == path then
        return cached.ok and path or nil
    end

    -- Ensure KOReader's fallback font search knows this exact, external path.
    -- This works with old ui/font.lua as well as newer builds that directly
    -- accept absolute filenames. Never change FontList.fontdir globally.
    local listed, files = pcall(FontList.getFontList, FontList)
    if listed and type(files) == "table" then
        local found = false
        for _, name in ipairs(files) do
            if name == path then found = true; break end
        end
        if not found then table.insert(files, path) end
    end

    local ok, face = pcall(Font.getFace, Font, path, 18)
    local valid = ok and type(face) == "table" and face.ftsize ~= nil
    runtime_font_cache[id] = {path=path, ok=valid}
    if not valid then
        logger.warn("FlipSide: rejected unreadable UI font", path,
            ok and "Font:getFace returned nil" or tostring(face))
        return nil
    end
    return path
end

local function filenameFamily(rel)
    local filename = rel:match("([^/]+)$") or rel
    local name = filename:gsub("%.[^.]+$", "")
        :gsub("[_%-]", " "):gsub("%s+", " ")
    -- Fallback for fonts with no family metadata (the usual case has real names).
    name = name:gsub("%s+[Bb]old[Ii]talic$", "")
        :gsub("%s+[Bb]old[Oo]blique$", "")
        :gsub("%s+[Rr]egular[Ii]talic$", "")
        :gsub("%s+[Rr]egular$", "")
        :gsub("%s+[Rr]oman$", "")
        :gsub("%s+[Ii]talic$", "")
        :gsub("%s+[Oo]blique$", "")
        :gsub("%s+[Bb]old$", "")
        :gsub("%s+[Mm]edium$", "")
    return (name:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fontInfo(path, rel)
    local cached = name_cache[path]
    if cached then return cached end
    local ok, ft_size = pcall(FT.newFaceSize, path, nil, 0)
    if not ok or not ft_size then return nil end
    -- FreeType exposes the actual family/style rather than the file basename.
    local info_ok, info = pcall(function()
        local ft_info = ft_size:getInfo()
        local family = ft_info and ft_info.name
        if type(family) ~= "string" or family == "" then
            family = filenameFamily(rel)
        end
        local style = ""
        if ft_size.face and ft_size.face.style_name ~= nil then
            local ok_style, value = pcall(require("ffi").string, ft_size.face.style_name)
            if ok_style and type(value) == "string" then style = value end
        end
        -- Non-standard font metadata occasionally bakes a style suffix into
        -- family_name itself; those are still the same family for this picker.
        local suffixes = { "Bold Italic", "BoldItalic", "Regular Italic",
            "RegularItalic", "SemiBold", "Semibold", "ExtraBold",
            "Bold", "Italic", "Oblique", "Regular", "Roman", "Medium" }
        for _, suffix in ipairs(suffixes) do
            local prefix = family:sub(1, #family - #suffix)
            if #family > #suffix + 2 and
                family:sub(-#suffix):lower() == suffix:lower() and
                (prefix:sub(-1) == " " or prefix:sub(-1) == "-") then
                family = prefix:sub(1, -2)
                break
            end
        end
        local lower = style:lower()
        local score = 0
        if lower == "regular" or lower == "roman" or lower == "book"
            or lower == "normal" or lower == "text" then
            score = 200
        elseif lower == "medium" then score = 130
        elseif lower == "light" then score = 90
        elseif lower == "bold" then score = 20
        end
        if not (ft_info and ft_info.bold) and not (ft_info and ft_info.italic) then
            score = score + 100
        end
        local f = rel:lower()
        if f:find("regular", 1, true) or f:find("roman", 1, true)
            or f:find("book", 1, true) then score = score + 30 end
        if f:find("bold", 1, true) or f:find("italic", 1, true)
            or f:find("oblique", 1, true) then score = score - 20 end
        return {family=family, style=style, score=score}
    end)
    ft_size:done()
    if not info_ok or not info then return nil end
    name_cache[path] = info
    return info
end

local function familyKey(name)
    -- Strip cosmetic differences in spacing/case only; do not confuse distinct
    -- families such as Noto Sans, Noto Serif and Noto Sans Display.
    return (name or ""):lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.label(id)
    if M.isRootId(id) then
        local path = M.resolve(id)
        local _, rel = parseId(id)
        local data = path and fontInfo(path, rel)
        return data and data.family or filenameFamily(rel or id)
    end
    if id == "palr45w.ttf" then return "Palatino" end
    if id == "EB_Garamond" then return "EB Garamond" end
    if id == "Andika" then return "Andika" end
    return "KOReader default"
end

-- Return family groups and a compact description of the searched roots.
function M.list()
    local families, all = {}, {}
    local visited_paths = {}
    local searched = {}
    for rank, dir in ipairs(USER_DIRS) do
        if dir.path and lfs.attributes(dir.path, "mode") == "directory" then
            searched[#searched + 1] = dir.path
            local ok, err = pcall(function()
                util.findFiles(dir.path, function(path, filename)
                    local ext = type(filename) == "string"
                        and filename:lower():match("%.([^.]+)$")
                    if not (ext and EXTENSIONS[ext]) then return end
                    if visited_paths[path] then return end
                    visited_paths[path] = true
                    -- util.findFiles emits full paths built from the root.
                    local prefix = dir.path .. "/"
                    if type(path) ~= "string" or path:sub(1, #prefix) ~= prefix then return end
                    local rel = path:sub(#prefix + 1)
                    local id = dir.key .. ":" .. rel
                    if not parseId(id) then return end
                    local metadata = fontInfo(path, rel)
                    if not metadata then return end
                    local key = familyKey(metadata.family)
                    if key == "" then return end
                    local entry = families[key]
                    if not entry then
                        entry = {
                            text = metadata.family,
                            id = id, path = path, source_rank = rank,
                            style_score = metadata.score, member_ids = {},
                        }
                        families[key] = entry
                        all[#all + 1] = entry
                    end
                    entry.member_ids[id] = true
                    -- Prefer a user's root fonts over bundled fonts, then
                    -- Regular over Bold/Italic within the same family/root.
                    if rank < entry.source_rank or
                        (rank == entry.source_rank and metadata.score > entry.style_score) then
                        entry.id = id
                        entry.path = path
                        entry.source_rank = rank
                        entry.style_score = metadata.score
                    end
                end)
            end)
            if not ok then
                logger.warn("FlipSide: could not scan user fonts in", dir.path, err)
            end
        end
    end
    table.sort(all, function(a, b)
        local al, bl = a.text:lower(), b.text:lower()
        if al ~= bl then return al < bl end
        return a.id < b.id
    end)
    return all, table.concat(searched, ", ")
end

function M.open(owner, selected_id, createMenu, onChoose)
    local families, searched = M.list()
    if #families == 0 then
        UIManager:show(InfoMessage:new{
            text = "No personal font families found. Place TTF/OTF files "
                .. "inside koreader/fonts (subfolders supported), then reopen "
                .. "this menu. Expected location: " .. personal_fonts .. ". "
                .. "Checked: " .. (searched ~= "" and searched or "no readable personal folders"),
            timeout = 7,
        })
        return false
    end
    local selected_path = M.resolve(selected_id)
    local items = {}
    for _, family in ipairs(families) do
        local selected = family.member_ids[selected_id] == true
            or (selected_path ~= nil and selected_path == family.path)
        items[#items + 1] = {
            text = (selected and "●  " or "○  ") .. family.text,
            font_id = family.id,
            bold = selected,
        }
    end
    items[#items + 1] = {text = "Done", is_done = true, bold = true}
    local menu
    menu = createMenu({
        title = "Choose font",
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_, item)
            if not item then return true end
            if item.is_done then
                UIManager:close(menu)
                return true
            end
            if item.font_id then
                local path = M.resolve(item.font_id)
                if not path or not M.renderable(item.font_id) then
                    UIManager:show(InfoMessage:new{
                        text = "KOReader cannot render this font. Choose another family. "
                            .. "Your existing selection was not changed.",
                        timeout = 5,
                    })
                    return true
                end
                UIManager:close(menu)
                onChoose(item.font_id)
            end
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

return M
