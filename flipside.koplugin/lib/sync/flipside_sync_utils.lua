-- Fast, bounded-memory sync comparisons. Read-only; no filesystem mutation.
-- They intentionally never trust mtimes alone (Kindle and Android clocks differ).
local M = {}
function M.sameFile(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local fa = io.open(a, "rb")
    if not fa then return false end
    local fb = io.open(b, "rb")
    if not fb then fa:close(); return false end
    local ok, same = pcall(function()
        local na, nb = fa:seek("end"), fb:seek("end")
        if not na or na ~= nb then return false end
        fa:seek("set", 0); fb:seek("set", 0)
        while true do
            local x, y = fa:read(64 * 1024), fb:read(64 * 1024)
            if x ~= y then return false end
            if not x then return true end
        end
    end)
    fa:close(); fb:close()
    return ok and same or false
end
-- For small CRAM snapshots, compare the actual values rather than the
-- encoded JSON ordering. Bound recursion to reject cycles/malformed objects.
local function deepEqual(a, b, depth, seen)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end
    if depth >= 20 or seen[a] then return false end
    seen[a] = true
    for k, v in pairs(a) do
        if not deepEqual(v, b[k], depth + 1, seen) then
            seen[a] = nil
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            seen[a] = nil
            return false
        end
    end
    seen[a] = nil
    return true
end
function M.sameData(a, b)
    return deepEqual(a, b, 0, {})
end
return M
