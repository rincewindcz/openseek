local Config = require "engine.core.config"

-- Window / display settings applied through love.window. The persisted values
-- live in engine/core/config (fullscreen, vsync, window_size); the advanced
-- options DISPLAY page edits them and calls apply(). The game letterboxes to any
-- window via engine/ui/layout, so any size is safe.
local Display = {}

-- Selectable windowed sizes, labelled as shown on the DISPLAY page. The label
-- doubles as the persisted value.
Display.SIZES = {
    { label = "1280 x 720",  w = 1280, h = 720 },
    { label = "1600 x 900",  w = 1600, h = 900 },
    { label = "1920 x 1080", w = 1920, h = 1080 },
    { label = "1024 x 768",  w = 1024, h = 768 },
    { label = "1280 x 960",  w = 1280, h = 960 },
}

local function size_for(value)
    for _, s in ipairs(Display.SIZES) do
        if s.label == value then return s end
    end
    return Display.SIZES[1]
end

-- The window-size options as {label, value} choices for the settings page.
function Display.size_choices()
    local out = {}
    for i, s in ipairs(Display.SIZES) do
        out[i] = { label = s.label, value = s.label }
    end
    return out
end

-- Push the persisted display settings onto the window. Called at startup and
-- whenever a DISPLAY option changes. A no-op on failure (headless / unsupported).
function Display.apply()
    local s = size_for(Config.window_size)
    pcall(love.window.setMode, s.w, s.h, {
        fullscreen     = Config.fullscreen and true or false,
        fullscreentype = "desktop",
        resizable      = love.system.getOS() ~= "Web",
        vsync          = Config.vsync and 1 or 0,
    })
end

return Display
