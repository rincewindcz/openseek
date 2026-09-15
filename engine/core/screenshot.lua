-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Window screenshots as PNG. Running from a source directory they go to
-- <source>/screenshots/; fused, web and mobile builds (or a missing folder) fall
-- back to screenshots/ in the save directory.
local Screenshot = {}

Screenshot.DIR = "screenshots"

local function unique_name()
    local base = "seek-" .. os.date("%Y%m%d-%H%M%S")
    local name = base .. ".png"
    local n = 1
    while love.filesystem.getInfo(Screenshot.DIR .. "/" .. name) do
        n = n + 1
        name = string.format("%s-%d.png", base, n)
    end
    return name
end

local function write_source(name, data)
    if love.filesystem.isFused() then return nil end
    local path = love.filesystem.getSource() .. "/" .. Screenshot.DIR .. "/" .. name
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(data)
    f:close()
    return path
end

local function write_save(name, data)
    love.filesystem.createDirectory(Screenshot.DIR)
    local rel = Screenshot.DIR .. "/" .. name
    if not love.filesystem.write(rel, data) then return nil end
    return love.filesystem.getSaveDirectory() .. "/" .. rel
end

-- Captures the frame being presented; the file is written once it is done.
function Screenshot.capture()
    love.graphics.captureScreenshot(function(image)
        local data = image:encode("png"):getString()
        local name = unique_name()
        local path = write_source(name, data) or write_save(name, data)
        print(path and ("screenshot: " .. path) or "screenshot: write failed")
    end)
end

return Screenshot
