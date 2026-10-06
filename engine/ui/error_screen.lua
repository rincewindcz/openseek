-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local utf8    = require "utf8"
local Class   = require "engine.core.class"
local Log     = require "engine.core.log"
local Version = require "engine.core.version"
local Assets  = require "engine.core.assets"

-- Replaces the LOVE error screen (love.errorhandler, set in main.lua). An
-- unhandled error writes a report into the save directory (the error, the
-- traceback, the build, the platform, the pack and the last log lines) and
-- shows the error with the report's location, in the look of the data setup
-- screen: both draw only what ships with the engine, so neither needs the pack.
-- Everything it reads is guarded, since any part of the game may be what broke.
local ErrorScreen = Class()

local REPORT_DIR   = "crashes"
local FONT_PATH    = "content/fonts/loaded/loaded.ttf"
local DESKTOP      = { Linux = true, Windows = true, ["OS X"] = true }
local HEADLESS_ARG = "--selftest"

local BACKDROP    = 0.25   -- brightness of the intro card behind the panel
local PANEL_W     = 0.8    -- panel width in screen widths
local PANEL_ALPHA = 0.8
local LINE_GAP    = 1.25
local SPACE       = 0.6    -- gap row, in small font heights
local TRACE_LINES = 12     -- traceback lines shown; the report holds all of them
local NOTICE_TIME = 2.5
local FRAME_SLEEP = 0.05

local WHITE = { 1, 1, 1 }
local GREY  = { 0.7, 0.7, 0.7 }
local GOLD  = { 1, 0.85, 0.3 }
local RED   = { 1, 0.4, 0.3 }

local DESKTOP_HINT = "C COPY REPORT    O OPEN FOLDER    R RESTART    ESC QUIT"
local TOUCH_HINT   = "TAP TO COPY THE REPORT"
local PAD_HINT     = "GAMEPAD    A RESTART    B QUIT"

-- fn's result, or "?" when it fails or returns nothing.
local function guarded(fn)
    local ok, value = pcall(fn)
    if ok and value ~= nil then return tostring(value) end
    return "?"
end

-- Text the fonts can take: an error message may carry bytes that are not UTF-8.
local function printable(text)
    if utf8.len(text) then return text end
    return (text:gsub("[\128-\255]", "?"))
end

-- The traceback as lines, without the LOVE boot frames and the chunk-name wrapping.
local function trace_lines(trace)
    local lines = {}
    for line in trace:gmatch("[^\n]+") do
        if not line:match("boot%.lua") and not line:match("^stack traceback:") then
            line = line:gsub("^%s+", ""):gsub('%[string "(.-)"%]', "%1")
            lines[#lines + 1] = line
        end
    end
    return lines
end

local function pack_line()
    local manifest = Assets.manifest()
    if not manifest then return Assets.pack_status() .. ", no manifest" end
    return ("%s, %s, schema %s"):format(Assets.pack_status(), tostring(manifest.edition), tostring(manifest.schema))
end

local function build_report(message, trace)
    local lines = { "openSEEK crash report", "" }
    local function field(label, fn)
        lines[#lines + 1] = ("%-10s%s"):format(label .. ":", guarded(fn))
    end
    field("time",     function() return os.date("%Y-%m-%d %H:%M:%S") end)
    field("version",  Version.string)
    field("love",     function() return ("%d.%d.%d (%s)"):format(love.getVersion()) end)
    field("lua",      function() return jit and jit.version or _VERSION end)
    field("os",       function() return love.system.getOS() end)
    field("renderer", function() return table.concat({ love.graphics.getRendererInfo() }, ", ") end)
    field("window",   function() return ("%d x %d"):format(love.graphics.getDimensions()) end)
    field("pack",     pack_line)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "error:"
    lines[#lines + 1] = message
    lines[#lines + 1] = ""
    lines[#lines + 1] = "traceback:"
    for _, line in ipairs(trace) do lines[#lines + 1] = line end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "log:"
    for _, line in ipairs(Log.recent()) do lines[#lines + 1] = line end
    return table.concat(lines, "\n") .. "\n"
end

-- Write the report; returns its absolute path, or nil when it could not be saved.
local function save_report(report)
    local ok, path = pcall(function()
        local name = REPORT_DIR .. "/crash_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
        love.filesystem.createDirectory(REPORT_DIR)
        if not love.filesystem.write(name, report) then return nil end
        return love.filesystem.getSaveDirectory() .. "/" .. name
    end)
    return ok and path or nil
end

local function headless()
    for _, a in ipairs(arg or {}) do
        if a == HEADLESS_ARG then return true end
    end
    return false
end

-- Leave whatever the game was doing: release the pointer, stop rumble and
-- sound, and drop every graphics state (canvas, shader, scissor, transform).
local function reset_devices()
    if love.mouse then
        love.mouse.setVisible(true)
        love.mouse.setGrabbed(false)
        love.mouse.setRelativeMode(false)
        if love.mouse.isCursorSupported() then love.mouse.setCursor() end
    end
    if love.joystick then
        for _, joystick in ipairs(love.joystick.getJoysticks()) do joystick:setVibration() end
    end
    if love.audio then love.audio.stop() end
    love.graphics.reset()
end

function ErrorScreen:init(message, trace, report, report_path, intro_path)
    self.message     = printable(message)
    self.report      = report
    self.report_path = report_path and printable(report_path) or nil
    self.desktop     = DESKTOP[guarded(function() return love.system.getOS() end)] or false
    self.pad         = love.joystick ~= nil and love.joystick.getJoystickCount() > 0
    self.notice      = nil
    self.notice_end  = 0
    local shown = {}
    for i = 1, math.min(#trace, TRACE_LINES) do shown[i] = trace[i] end
    if #trace > TRACE_LINES then shown[#shown + 1] = "..." end
    self.trace_text = printable(table.concat(shown, "\n"))
    local ok, intro = pcall(love.graphics.newImage, intro_path)
    if ok then
        intro:setFilter("linear", "linear")
        self.intro = intro
    end
end

function ErrorScreen:_fonts(screen_h)
    local size = math.max(12, math.floor(screen_h / 20))
    if size == self.font_size then return end
    local g      = love.graphics
    local small  = math.max(10, math.floor(size * 0.55))
    local styled = love.filesystem.getInfo(FONT_PATH) ~= nil
    self.font_size  = size
    self.font       = styled and g.newFont(FONT_PATH, size) or g.newFont(size)
    self.small_font = styled and g.newFont(FONT_PATH, small) or g.newFont(small)
    -- Paths and tracebacks are mixed case and long: the plain LOVE face.
    self.text_font  = g.newFont(math.max(10, math.floor(size * 0.45)))
end

function ErrorScreen:_notify(text)
    self.notice     = text
    self.notice_end = love.timer and love.timer.getTime() + NOTICE_TIME or 0
end

function ErrorScreen:_copy()
    if love.system and pcall(love.system.setClipboardText, self.report) then
        self:_notify("REPORT COPIED TO THE CLIPBOARD")
    end
end

function ErrorScreen:_open_folder()
    if not (self.report_path and love.system) then return end
    pcall(love.system.openURL, "file://" .. love.filesystem.getSaveDirectory() .. "/" .. REPORT_DIR)
end

-- Handle one LOVE event; returns the exit status (or "restart") to leave with.
function ErrorScreen:event(name, a, b)
    if name == "quit" then return 1 end
    if name == "keypressed" then
        if a == "escape" then return 1 end
        if a == "r" then return "restart" end
        if a == "c" then self:_copy() end
        if a == "o" then self:_open_folder() end
    elseif name == "gamepadpressed" then
        if b == "b" then return 1 end
        if b == "a" then return "restart" end
    elseif name == "touchpressed" or (name == "mousepressed" and not self.desktop) then
        self:_copy()
    end
    return nil
end

-- The text block, top to bottom: { font, text, color, align } rows and
-- { space = true } gaps.
function ErrorScreen:_rows()
    local rows = {}
    local function add(font, text, color, align)
        rows[#rows + 1] = { font = font, text = text, color = color, align = align or "center" }
    end
    local function space() rows[#rows + 1] = { space = true } end
    add(self.font, "OPENSEEK HAS CRASHED", WHITE)
    space()
    add(self.text_font, self.message, RED)
    space()
    if self.report_path then
        add(self.small_font, "A REPORT WAS SAVED TO", GREY)
        add(self.text_font, self.report_path, GOLD)
    else
        add(self.small_font, "THE REPORT COULD NOT BE SAVED", GREY)
    end
    space()
    if self.notice then
        add(self.small_font, self.notice, GOLD)
    else
        add(self.small_font, self.desktop and DESKTOP_HINT or TOUCH_HINT, GREY)
        if self.pad then add(self.small_font, PAD_HINT, GREY) end
    end
    space()
    add(self.text_font, self.trace_text, GREY, "left")
    return rows
end

function ErrorScreen:_row_height(row, width)
    if row.space then return self.small_font:getHeight() * SPACE end
    local _, wrapped = row.font:getWrap(row.text, width)
    return math.max(1, #wrapped) * row.font:getHeight() * LINE_GAP
end

function ErrorScreen:draw()
    local g = love.graphics
    if not g.isActive() then return end
    local screen_w, screen_h = g.getDimensions()
    self:_fonts(screen_h)
    if self.notice and love.timer and love.timer.getTime() >= self.notice_end then self.notice = nil end

    g.origin()
    g.clear(0, 0, 0, 1)
    if self.intro then
        local img_w, img_h = self.intro:getDimensions()
        local scale = math.min(screen_w / img_w, screen_h / img_h)
        g.setColor(BACKDROP, BACKDROP, BACKDROP, 1)
        g.draw(self.intro, (screen_w - img_w * scale) / 2, (screen_h - img_h * scale) / 2, 0, scale, scale)
    end

    local pad     = self.small_font:getHeight()
    local panel_w = math.floor(screen_w * PANEL_W)
    local text_w  = panel_w - pad * 2
    local rows    = self:_rows()
    local total   = 0
    for _, row in ipairs(rows) do total = total + self:_row_height(row, text_w) end
    local left = math.floor((screen_w - panel_w) / 2)
    local top  = math.max(pad, math.floor((screen_h - total) / 2))
    g.setColor(0, 0, 0, PANEL_ALPHA)
    g.rectangle("fill", left, top - pad, panel_w, total + pad * 2, pad * 0.5)
    g.setColor(0.45, 0.45, 0.8, 0.5)
    g.rectangle("line", left, top - pad, panel_w, total + pad * 2, pad * 0.5)

    local y = top
    for _, row in ipairs(rows) do
        if row.text then
            g.setFont(row.font)
            g.setColor(row.color[1], row.color[2], row.color[3], 1)
            g.printf(row.text, left + pad, math.floor(y), text_w, row.align)
        end
        y = y + self:_row_height(row, text_w)
    end
    g.setColor(1, 1, 1, 1)
    g.present()
end

-- Builds love.errorhandler: the returned function reports the error and
-- returns the loop LOVE runs in place of the game (nil ends the process with
-- status 1). intro_path is the engine intro card drawn behind the text.
function ErrorScreen.handler(intro_path)
    return function(message)
        message = tostring(message)
        local trace  = trace_lines(debug.traceback("", 2))
        print("Error: " .. message .. "\n" .. table.concat(trace, "\n"))
        local report = build_report(message, trace)
        local path   = save_report(report)
        if path then print("crash report: " .. path) end
        -- A scripted run has nobody to read the screen: fail it instead of waiting.
        if headless() or not (love.window and love.graphics and love.event) then return nil end
        if not love.window.isOpen() then
            local ok, opened = pcall(love.window.setMode, 800, 600)
            if not (ok and opened) then return nil end
        end
        reset_devices()

        local screen = ErrorScreen:new(message, trace, report, path, intro_path)
        return function()
            love.event.pump()
            for name, a, b in love.event.poll() do
                local status = screen:event(name, a, b)
                if status then return status end
            end
            screen:draw()
            if love.timer then love.timer.sleep(FRAME_SLEEP) end
        end
    end
end

return ErrorScreen
