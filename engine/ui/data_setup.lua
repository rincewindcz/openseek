-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local Gamepad = require "engine.core.gamepad"

-- First-run screen shown when the game data pack is missing or outdated. It
-- runs before anything from the pack loads, so it draws only the engine intro
-- card and the shipped TTF. On desktop it offers to build the pack with the
-- converter (tools/build_pack.py, shipped as openseek-setup.pyz next to the
-- game) from the downloaded shareware release or
-- the user's own copy, then restarts LOVE into the game. Elsewhere (web,
-- mobile) it only reports the missing data.
local DataSetup = Class()

local FADE_IN     = 0.25
local HOLD        = 0.8
local DIM_TIME    = 0.5
local DIM         = 0.45
local LIFT        = 0.22   -- screen heights the intro card rises once dimmed
local PANEL_TOP   = 0.5    -- highest the text panel starts, in screen heights
local PANEL_ALPHA = 0.75

local FONT_PATH = "content/fonts/loaded/loaded.ttf"
local DESKTOP   = { Linux = true, Windows = true, ["OS X"] = true }

-- Converter phases in the order they run, each an equal share of the bar.
local PHASES       = { "download", "unpack", "convert" }
local LOCAL_PHASES = { "unpack", "convert" }

local THREAD_CODE = [[
local command, channel = ...
local pipe = io.popen(command, "r")
if pipe then
    for line in pipe:lines() do channel:push(line) end
    pipe:close()
end
channel:push("\0end")
]]

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local function windows()
    return love.system.getOS() == "Windows"
end

local function quote(s)
    if windows() then return '"' .. s:gsub('"', "") .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- The converter invocation, or nil when none ships with this build: the
-- Python zipapp, or the repo script when running from a source checkout. The
-- Windows download carries its own Python next to the game.
local function converter()
    local base   = love.filesystem.getSourceBaseDirectory()
    local source = love.filesystem.getSource()
    local python = windows() and "py -3" or "python3"
    if windows() and file_exists(base .. "/python/python.exe") then
        python = quote(base .. "/python/python.exe")
    end
    if file_exists(base .. "/openseek-setup.pyz") then
        return python .. " " .. quote(base .. "/openseek-setup.pyz")
    end
    if not love.filesystem.isFused() and file_exists(source .. "/tools/build_pack.py") then
        return python .. " " .. quote(source .. "/tools/build_pack.py")
    end
    return nil
end

function DataSetup:init(status, intro_path, manifest)
    self.status     = status
    self.manifest   = manifest
    self.intro      = love.graphics.newImage(intro_path)
    self.elapsed    = 0
    self.command    = DESKTOP[love.system.getOS()] and converter() or nil
    self.mode       = self.command and "menu" or "report"
    self.selected   = 1
    self.path       = ""
    self.lines      = {}
    self.progress   = 0
    self.label      = ""
    self.error      = nil
    self.items      = {}
    self.item_rects = {}
    self.intro:setFilter("linear", "linear")
    if self.command then
        if status == "outdated" and manifest and manifest.source then
            self.items[#self.items + 1] = { id = "rebuild", text = "REBUILD GAME DATA",
                hint = "Convert the previous source again for this version." }
        end
        self.items[#self.items + 1] = { id = "download", text = "DOWNLOAD SHAREWARE",
            hint = "Seek and Destroy v1.0 shareware (missions 1-2) from the internet." }
        self.items[#self.items + 1] = { id = "path", text = "USE MY COPY",
            hint = "A folder with DATA.JAM, or a release .zip. You can also drop it here." }
    end
    self.items[#self.items + 1] = { id = "quit", text = "QUIT", hint = "" }
end

function DataSetup:title()
    return self.status == "outdated" and "GAME DATA OUTDATED" or "MISSING GAME DATA"
end

function DataSetup:_dim_start()
    return FADE_IN + HOLD
end

function DataSetup:_skip_intro()
    self.elapsed = math.max(self.elapsed, self:_dim_start() + DIM_TIME)
end

-- conversion

function DataSetup:_start(args, download)
    local save = love.filesystem.getSaveDirectory()
    love.filesystem.createDirectory("downloads")
    local command = self.command .. " " .. args
        .. " --out " .. quote(save .. "/assets")
        .. " --cache " .. quote(save .. "/downloads") .. " 2>&1"
    if windows() then command = '"' .. command .. '"' end
    self.channel  = love.thread.newChannel()
    self.thread   = love.thread.newThread(THREAD_CODE)
    self.mode     = "running"
    self.phases   = download and PHASES or LOCAL_PHASES
    self.progress = 0
    self.label    = "STARTING"
    self.lines    = {}
    self.error    = nil
    self.done     = false
    self.thread:start(command, self.channel)
end

function DataSetup:_choose(id)
    if id == "quit" then
        love.event.quit()
    elseif id == "download" then
        self:_start("--download", true)
    elseif id == "rebuild" then
        local source = self.manifest.source
        if source == "download" then
            self:_start("--download", true)
        else
            self:_start(quote(source))
        end
    elseif id == "path" then
        self.mode = "path"
        love.keyboard.setKeyRepeat(true)
    end
end

function DataSetup:_use_path(path)
    path = path:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^"(.*)"$', "%1")
    if path == "" then return end
    love.keyboard.setKeyRepeat(false)
    self:_start(quote(path))
end

-- Moves the bar to `fraction` of `phase`; it never moves backwards.
function DataSetup:_advance(phase, fraction)
    for i, name in ipairs(self.phases) do
        if name == phase then
            self.progress = math.max(self.progress, (i - 1 + fraction) / #self.phases)
        end
    end
end

function DataSetup:_handle_line(line)
    self.lines[#self.lines + 1] = line
    local step, total, name = line:match("^%[(%d+)/(%d+)%] (%S+)")
    local download = line:match("^download (%d+)%%")
    local unpack   = line:match("^unpack (%d+)%%")
    if step then
        self:_advance("convert", (tonumber(step) - 1) / tonumber(total))
        self.label = name:gsub("^export_", ""):gsub("_", " "):upper()
    elseif download then
        self:_advance("download", tonumber(download) / 100)
        self.label = "DOWNLOADING " .. download .. "%"
    elseif line:match("^download cached ") then
        self:_advance("download", 1)
    elseif unpack then
        self:_advance("unpack", tonumber(unpack) / 100)
        self.label = "UNPACKING " .. unpack .. "%"
    elseif line:match("^ERROR ") then
        self.error = line:sub(7)
    elseif line:match("^DONE ") then
        self.progress = 1
        self.done     = true
    end
end

function DataSetup:_finish()
    if self.done then
        love.event.quit("restart")
        return
    end
    self.mode  = "error"
    self.error = self.error or self.lines[#self.lines] or "the converter did not start"
end

function DataSetup:update(dt)
    self.elapsed = self.elapsed + dt
    if self.mode ~= "running" then return end
    local line = self.channel:pop()
    while line do
        if line == "\0end" then
            self:_finish()
            return
        end
        self:_handle_line(line)
        line = self.channel:pop()
    end
    local err = self.thread:getError()
    if err then
        self.error = err
        self.mode  = "error"
    end
end

-- input

function DataSetup:keypressed(key)
    if self.elapsed < self:_dim_start() + DIM_TIME then
        if key == "escape" then love.event.quit() end
        self:_skip_intro()
        return
    end
    if self.mode == "menu" then
        if key == "up" then
            self.selected = (self.selected - 2) % #self.items + 1
        elseif key == "down" or key == "tab" then
            self.selected = self.selected % #self.items + 1
        elseif key == "return" or key == "kpenter" or key == "space" then
            self:_choose(self.items[self.selected].id)
        elseif key == "escape" then
            love.event.quit()
        end
    elseif self.mode == "path" then
        local ctrl = love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")
        if key == "return" or key == "kpenter" then
            self:_use_path(self.path)
        elseif key == "backspace" then
            self.path = self.path:sub(1, -2)
        elseif key == "v" and ctrl then
            self.path = self.path .. (love.system.getClipboardText() or "")
        elseif key == "escape" then
            love.keyboard.setKeyRepeat(false)
            self.mode = "menu"
        end
    elseif self.mode == "error" then
        self.mode = "menu"
    elseif self.mode == "report" and key == "escape" then
        love.event.quit()
    end
end

function DataSetup:textinput(text)
    if self.mode == "path" then self.path = self.path .. text end
end

function DataSetup:mousereleased(x, y)
    if self.elapsed < self:_dim_start() + DIM_TIME then
        self:_skip_intro()
        return
    end
    if self.mode == "error" then
        self.mode = "menu"
        return
    end
    if self.mode ~= "menu" then return end
    for i, r in pairs(self.item_rects) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
            self.selected = i
            self:_choose(self.items[i].id)
            return
        end
    end
end

function DataSetup:mousemoved(x, y)
    if self.mode ~= "menu" then return end
    for i, r in pairs(self.item_rects) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then self.selected = i end
    end
end

function DataSetup:dropped(path)
    if self.mode == "menu" or self.mode == "path" or self.mode == "error" then
        self:_use_path(path)
    end
end

-- drawing

local WHITE = { 1, 1, 1 }
local GREY  = { 0.7, 0.7, 0.7 }
local GOLD  = { 1, 0.85, 0.3 }
local RED   = { 1, 0.4, 0.3 }

function DataSetup:_fonts(screen_h)
    local size = math.max(12, math.floor(screen_h / 18))
    if size ~= self.font_size then
        self.font       = love.graphics.newFont(FONT_PATH, size)
        self.small_font = love.graphics.newFont(FONT_PATH, math.max(10, math.floor(size * 0.55)))
        self.font_size  = size
    end
end

-- The text block for the current mode, top to bottom: { font, text, color,
-- item index } rows, a "bar" row for the progress bar, a "space" row for a gap.
function DataSetup:_rows()
    local rows, small = {}, self.small_font
    local function add(text, color, item) rows[#rows + 1] = { font = small, text = text, color = color, item = item } end
    local function space() rows[#rows + 1] = { space = true } end
    rows[1] = { font = self.font, text = self:title(), color = WHITE }
    space()
    if self.mode == "menu" or self.mode == "report" then
        for i, item in ipairs(self.items) do
            local selected = i == self.selected and self.mode == "menu"
            add(selected and ("> " .. item.text .. " <") or item.text, selected and GOLD or WHITE, i)
        end
        if self.mode == "menu" then
            space()
            add(self.items[self.selected].hint, GREY)
        end
    elseif self.mode == "path" then
        add("TYPE OR PASTE (CTRL+V) THE PATH, OR DROP IT HERE", GREY)
        space()
        add(self.path .. ((math.floor(self.elapsed * 2) % 2 == 0) and "_" or " "), WHITE)
        space()
        add("ENTER TO CONVERT, ESC TO GO BACK", GREY)
    elseif self.mode == "running" then
        add(self.label, WHITE)
        rows[#rows + 1] = { bar = true }
    elseif self.mode == "error" then
        add("CONVERSION FAILED", RED)
        for text in tostring(self.error):gmatch("[^\n]+") do add(text, WHITE) end
        space()
        add("PRESS ANY KEY", GREY)
    end
    return rows
end

function DataSetup:_row_height(row)
    if row.space then return self.small_font:getHeight() * 0.6 end
    if row.bar then return self.small_font:getHeight() * 1.2 end
    return row.font:getHeight() * 1.25
end

-- Widest text the menu can show, so its panel keeps one size as the selection moves.
function DataSetup:_menu_width()
    local width = 0
    for _, item in ipairs(self.items) do
        width = math.max(width, self.small_font:getWidth("> " .. item.text .. " <"),
            self.small_font:getWidth(item.hint))
    end
    return width
end

function DataSetup:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    self:_fonts(screen_h)
    local dim = math.min(1, math.max(0, (self.elapsed - self:_dim_start()) / DIM_TIME))
    local brightness = math.min(1, self.elapsed / FADE_IN) * (1 - dim * (1 - DIM))
    local ease = dim * dim * (3 - 2 * dim)

    -- The intro card slides up so its logo clears the text panel below it.
    g.clear(0, 0, 0, 1)
    local img_w, img_h = self.intro:getDimensions()
    local scale = math.min(screen_w / img_w, screen_h / img_h)
    local img_y = (screen_h - img_h * scale) / 2 - ease * screen_h * LIFT
    g.setColor(brightness, brightness, brightness, 1)
    g.draw(self.intro, (screen_w - img_w * scale) / 2, img_y, 0, scale, scale)

    local rows = self:_rows()
    local total, width = 0, 0
    for _, row in ipairs(rows) do
        total = total + self:_row_height(row)
        if row.text then width = math.max(width, row.font:getWidth(row.text)) end
    end
    if self.mode == "menu" then width = math.max(width, self:_menu_width()) end
    local pad     = self.small_font:getHeight()
    local top     = math.max(screen_h * PANEL_TOP, screen_h - total - pad * 3)
    local panel_w = math.min(screen_w - pad * 2, math.max(width, screen_w * 0.45) + pad * 4)
    g.setColor(0, 0, 0, PANEL_ALPHA * dim)
    g.rectangle("fill", (screen_w - panel_w) / 2, top - pad, panel_w, total + pad * 2, pad * 0.5)
    g.setColor(0.45, 0.45, 0.8, 0.5 * dim)
    g.rectangle("line", (screen_w - panel_w) / 2, top - pad, panel_w, total + pad * 2, pad * 0.5)

    self.item_rects = {}
    local y = top
    for _, row in ipairs(rows) do
        local h = self:_row_height(row)
        if row.bar then
            local bar_w, bar_h = panel_w - pad * 4, math.max(4, math.floor(pad * 0.4))
            local bar_x = (screen_w - bar_w) / 2
            local bar_y = y + (h - bar_h) / 2
            g.setColor(1, 1, 1, 0.25 * dim)
            g.rectangle("fill", bar_x, bar_y, bar_w, bar_h)
            g.setColor(GOLD[1], GOLD[2], GOLD[3], dim)
            g.rectangle("fill", bar_x, bar_y, bar_w * self.progress, bar_h)
        elseif row.text then
            local w = row.font:getWidth(row.text)
            local x = math.floor((screen_w - w) / 2)
            g.setFont(row.font)
            g.setColor(row.color[1], row.color[2], row.color[3], dim)
            g.print(row.text, x, math.floor(y))
            if row.item then self.item_rects[row.item] = { x = x, y = y, w = w, h = h } end
        end
        y = y + h
    end
    g.setColor(1, 1, 1, 1)
end

-- Route the LOVE callbacks to the setup screen; the regular app never loads.
function DataSetup:install()
    love.wheelmoved, love.touchmoved, love.touchpressed, love.touchreleased = nil, nil, nil, nil
    love.mousepressed = nil
    love.update           = function(dt) self:update(dt) end
    love.draw             = function() self:draw() end
    love.keypressed       = function(key) self:keypressed(key) end
    -- A gamepad steps the menu as the keys its buttons stand for.
    love.gamepadaxis      = nil
    love.gamepadpressed   = function(_, button)
        local key = Gamepad.MENU_KEYS[button]
        if key then self:keypressed(key) end
    end
    love.textinput        = function(text) self:textinput(text) end
    love.mousereleased    = function(x, y) self:mousereleased(x, y) end
    love.mousemoved       = function(x, y) self:mousemoved(x, y) end
    love.directorydropped = function(path) self:dropped(path) end
    love.filedropped      = function(file) self:dropped(file:getFilename()) end
end

return DataSetup
