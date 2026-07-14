local Class   = require "engine.core.class"
local Scene   = require "engine.core.scene"
local Font    = require "engine.core.font"
local Layout  = require "engine.ui.layout"
local Config  = require "engine.core.config"
local Input   = require "engine.core.input"
local Audio   = require "engine.core.audio"
local Display = require "engine.core.display"
local Pointer = require "engine.ui.pointer"

-- Advanced OpenSeek options: a category sidebar (VIDEO / AUDIO / CONTROLS /
-- GAMEPLAY / EXTRAS / EXIT) with the selected category's option rows on the right,
-- over the pulsating main-menu backdrop. Reached from the main menu's OPTIONS
-- entry. Toggles/ranges edit engine/core/config live; CONTROLS rebinds the central
-- key map (engine/core/input). Config and bindings are written to the save
-- directory on exit.
local AdvancedSettings = Class(Scene)

AdvancedSettings.ui_pointer = true

local DESIGN_W, DESIGN_H = Layout.DESIGN_W, Layout.DESIGN_H

-- Layout in design space (320x240).
local PANEL_X, PANEL_Y, PANEL_W, PANEL_H = 16, 30, 288, 190
local TITLE_Y   = 36
local DIVIDER_X = 114
local SIDE_X    = 30    -- category label x
local SIDE_HIT0 = 22    -- sidebar hit-test left / right
local SIDE_HIT1 = 110
local SIDE_Y0   = 56
local CAT_DY    = 17
local PANEL_LX  = 122   -- option label x
local VALUE_RX  = 298   -- option value right edge
local ROW_Y0    = 56
local ROW_DY    = 16
local ROW_H     = 12
local ARROW_GAP = 8
local FADE_IN   = 0.25
local FOOTER_Y  = 210

local function apply_volume()  Audio.set_master(Config.master_volume) end
local function apply_display() Display.apply() end

-- Categories listed in the sidebar. A category with `options` shows a rows panel;
-- `kind = "controls"` builds its rows from the rebindable input actions; `kind =
-- "exit"` leaves the screen when chosen. Every option key is a persisted Config
-- field (or, for keybinds, an Input action).
local CATEGORIES = {
    { title = "DISPLAY", options = {
        { key = "fullscreen",  label = "FULLSCREEN",  kind = "toggle", on_change = apply_display },
        { key = "window_size", label = "WINDOW SIZE", kind = "choice", choices = Display.size_choices(), on_change = apply_display },
        { key = "vsync",       label = "VSYNC",       kind = "toggle", on_change = apply_display },
        { key = "show_fps",    label = "SHOW FPS",    kind = "toggle" },
    } },
    { title = "VIDEO", options = {
        { key = "effects_flashes",  label = "FLASH FX",      kind = "toggle" },
        { key = "flash_intensity",  label = "FLASH LEVEL",   kind = "range", min = 0.0, max = 1.5, step = 0.1 },
        { key = "night_lighting",   label = "NIGHT LIGHT",   kind = "toggle" },
        { key = "night_brightness", label = "NIGHT AMBIENT", kind = "range", min = 0.5, max = 2.0, step = 0.1 },
    } },
    { title = "AUDIO", options = {
        { key = "master_volume", label = "MASTER VOLUME", kind = "range", min = 0.0, max = 1.0, step = 0.05, on_change = apply_volume },
    } },
    { title = "CONTROLS", kind = "controls" },
    { title = "GAMEPLAY", options = {
        { key = "speed_scale",          label = "GAME SPEED",      kind = "range", min = 0.5, max = 1.2, step = 0.1 },
        { key = "hud_scale",            label = "HUD SIZE",        kind = "range", min = 0.8, max = 1.6, step = 0.1 },
        { key = "axis_aligned_pickups", label = "CLASSIC PICKUPS", kind = "toggle" },
        { key = "friendly_fire_pows",   label = "FRIENDLY FIRE",   kind = "toggle" },
        { key = "endstats_count_up",    label = "STATS COUNT UP",  kind = "toggle" },
    } },
    { title = "EXTRAS", options = {
        { key = "explosive_trees",  label = "EXPLOSIVE TREES", kind = "toggle" },
        { key = "tree_crush_speed", label = "CRUSH SPEED",     kind = "range", min = 0.3, max = 1.0, step = 0.1 },
    } },
    { title = "EXIT", kind = "exit" },
}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function AdvancedSettings:init(app)
    Scene.init(self, app)
    self.font      = Font.get("chars")
    self.cat       = 1
    self.cursor    = 1
    self.focus     = "menu"   -- "menu" (sidebar) or "panel" (option rows)
    self.capturing = nil      -- input action awaiting a key press, or nil
    self.t         = 0

    -- CONTROLS rows, built once from the rebindable actions plus a reset action.
    self.control_opts = {}
    for _, a in ipairs(Input.ACTIONS) do
        self.control_opts[#self.control_opts + 1] = { label = a.label, action = a.key, kind = "keybind" }
    end
    self.control_opts[#self.control_opts + 1] = { label = "RESET TO DEFAULTS", kind = "reset" }

    local ok, img = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
    if ok then img:setFilter("linear", "linear"); self.bg = img end
    local aok, arrow = pcall(love.graphics.newImage, "assets/mainmen/arrow.png")
    if aok then arrow:setFilter("nearest", "nearest"); self.arrow = arrow end
end

function AdvancedSettings:enter()
    self.t = 0; self.cat = 1; self.cursor = 1; self.focus = "menu"; self.capturing = nil
end

function AdvancedSettings:_category() return CATEGORIES[self.cat] end

function AdvancedSettings:_options()
    local cat = self:_category()
    if cat.kind == "controls" then return self.control_opts end
    if cat.kind == "exit"     then return {} end
    return cat.options or {}
end

-- Persist config + bindings and return to the menu.
function AdvancedSettings:_exit()
    Config.save()
    Input.save()
    self.app.scenes:replace("main_menu")
end

function AdvancedSettings:_move_cat(dir)
    self.cat    = ((self.cat - 1 + dir) % #CATEGORIES) + 1
    self.cursor = 1
end

function AdvancedSettings:_move(dir)
    local n = #self:_options()
    if n == 0 then return end
    self.cursor = ((self.cursor - 1 + dir) % n) + 1
end

-- Open the selected category: leave for EXIT, otherwise move focus into its rows.
function AdvancedSettings:_enter_category()
    local cat = self:_category()
    if cat.kind == "exit" then self:_exit(); return end
    if #self:_options() > 0 then self.focus = "panel"; self.cursor = 1 end
end

-- Change the focused option. dir is +1 / -1 (a toggle ignores its magnitude); a
-- keybind starts capturing a new key.
function AdvancedSettings:_activate(dir)
    local opt = self:_options()[self.cursor]
    if not opt then return end
    if opt.kind == "keybind" then
        self.capturing = opt.action
    elseif opt.kind == "reset" then
        Input.reset()
    elseif opt.kind == "toggle" then
        Config[opt.key] = not Config[opt.key]
        if opt.on_change then opt.on_change() end
    elseif opt.kind == "choice" then
        local idx = 1
        for i, c in ipairs(opt.choices) do
            if c.value == Config[opt.key] then idx = i; break end
        end
        idx = ((idx - 1 + dir) % #opt.choices) + 1
        Config[opt.key] = opt.choices[idx].value
        if opt.on_change then opt.on_change() end
    else
        local v = Config[opt.key] + opt.step * dir
        v = math.floor(v / opt.step + 0.5) * opt.step   -- snap off float drift
        Config[opt.key] = clamp(v, opt.min, opt.max)
        if opt.on_change then opt.on_change() end
    end
end

function AdvancedSettings:keypressed(key)
    if self.capturing then
        if key ~= "escape" then Input.rebind(self.capturing, key) end
        self.capturing = nil
        return
    end
    if self.focus == "menu" then
        if     key == "up"   then self:_move_cat(-1)
        elseif key == "down" then self:_move_cat(1)
        elseif key == "right" or key == "return" or key == "space" or key == "kpenter" then self:_enter_category()
        elseif key == "escape" then self:_exit() end
    else
        if     key == "up"    then self:_move(-1)
        elseif key == "down"  then self:_move(1)
        elseif key == "left"  then self:_activate(-1)
        elseif key == "right" then self:_activate(1)
        elseif key == "return" or key == "space" or key == "kpenter" then self:_activate(1)
        elseif key == "escape" then self.focus = "menu" end
    end
end

function AdvancedSettings:_value_text(opt)
    if opt.kind == "keybind" then
        if self.capturing == opt.action then return "PRESS KEY" end
        return Input.display(opt.action)
    elseif opt.kind == "reset" then
        return ""
    elseif opt.kind == "toggle" then
        return Config[opt.key] and "ON" or "OFF"
    elseif opt.kind == "choice" then
        for _, c in ipairs(opt.choices) do
            if c.value == Config[opt.key] then return c.label end
        end
        return tostring(Config[opt.key])
    end
    return string.format("%d%%", math.floor(Config[opt.key] * 100 + 0.5))
end

-- Sidebar category under a window-space point, or nil.
function AdvancedSettings:_sidebar_at(x, y)
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    if dx < SIDE_HIT0 or dx > SIDE_HIT1 then return nil end
    for i = 1, #CATEGORIES do
        local ry = SIDE_Y0 + (i - 1) * CAT_DY
        if dy >= ry - 3 and dy <= ry + ROW_H then return i end
    end
    return nil
end

-- Panel option row under a window-space point, or nil.
function AdvancedSettings:_panel_at(x, y)
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    if dx < PANEL_LX - 4 or dx > VALUE_RX + 4 then return nil end
    for i = 1, #self:_options() do
        local ry = ROW_Y0 + (i - 1) * ROW_DY
        if dy >= ry - 3 and dy <= ry + ROW_H then return i end
    end
    return nil
end

function AdvancedSettings:mousemoved(x, y)
    if self.capturing then return end
    local ci = self:_sidebar_at(x, y)
    if ci then
        self.focus = "menu"
        if ci ~= self.cat then self.cat = ci; self.cursor = 1 end
        return
    end
    local pi = self:_panel_at(x, y)
    if pi then self.focus = "panel"; self.cursor = pi end
end

-- Click a category to open it, or an option to change it: toggles flip, ranges
-- step up on the right half and down on the left half, keybinds start capturing.
function AdvancedSettings:mousepressed(x, y)
    if self.capturing then self.capturing = nil; return end
    local ci = self:_sidebar_at(x, y)
    if ci then
        if ci ~= self.cat then self.cat = ci; self.cursor = 1 end
        self:_enter_category()
        return
    end
    local pi = self:_panel_at(x, y)
    if not pi then return end
    self.focus  = "panel"
    self.cursor = pi
    local opt = self:_options()[pi]
    if not opt then return end
    if opt.kind == "range" or opt.kind == "choice" then
        local dx = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
        self:_activate(dx >= (PANEL_LX + VALUE_RX) / 2 and 1 or -1)
    else
        self:_activate(1)
    end
end

function AdvancedSettings:update(dt) self.t = self.t + dt end

-- The blinking selection arrow to the left of a row at (x, y).
function AdvancedSettings:_arrow(x, y, fade)
    if not self.arrow then return end
    local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
    local phase  = 0.5 + 0.5 * math.sin(self.t * 2.2)
    love.graphics.setColor(1, 1, 1, fade)
    love.graphics.draw(self.arrow, x - ARROW_GAP - aw / 2 + 3 * phase,
        y + self.font.line_height / 2, 0, 1, 1, aw / 2, ah / 2)
end

function AdvancedSettings:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade = math.min(1, self.t / FADE_IN)

    -- Pulsating backdrop, matching the main menu (breathing zoom, fade-in).
    if self.bg then
        local breathe = 1 + 0.015 * (1 + math.sin(self.t * 0.5)) / 2
        local bw, bh  = screen_w * breathe, screen_h * breathe
        g.setColor(fade, fade, fade, 1)
        g.draw(self.bg, (screen_w - bw) / 2, (screen_h - bh) / 2, 0,
            bw / self.bg:getWidth(), bh / self.bg:getHeight())
    else
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", 0, 0, screen_w, screen_h)
    end

    local scale, ox, oy = Layout.fit(screen_w, screen_h)
    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)

    g.setColor(0, 0, 0, 0.6 * fade)
    g.rectangle("fill", PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 4)

    local title = "ADVANCED OPTIONS"
    self.font:print(title, (DESIGN_W - self.font:width(title)) / 2, TITLE_Y,
        { color = { 1, 1, 1, fade } })

    g.setColor(1, 1, 1, 0.25 * fade)
    g.rectangle("fill", DIVIDER_X, SIDE_Y0 - 2, 1, CAT_DY * #CATEGORIES - 4)
    g.setColor(1, 1, 1, 1)

    -- Sidebar categories; the active one is bright (brighter while it holds focus).
    local menu_focus = self.focus == "menu"
    for i, cat in ipairs(CATEGORIES) do
        local ry  = SIDE_Y0 + (i - 1) * CAT_DY
        local sel = (i == self.cat)
        local a   = ((sel and (menu_focus and 1 or 0.85)) or 0.5) * fade
        if cat.kind == "exit" then
            g.setColor(1, 1, 1, 0.25 * fade)
            g.rectangle("fill", SIDE_X - 2, ry - 5, SIDE_HIT1 - SIDE_X, 1)
        end
        self.font:print(cat.title, SIDE_X, ry, { color = { 1, 1, 1, a } })
        if sel and menu_focus then self:_arrow(SIDE_X, ry, fade) end
    end

    -- Option rows for the active category.
    local cat = self:_category()
    if cat.kind == "exit" then
        self.font:print("PRESS ENTER TO EXIT", PANEL_LX, ROW_Y0, { color = { 1, 1, 1, 0.7 * fade } })
    else
        for i, opt in ipairs(self:_options()) do
            local y   = ROW_Y0 + (i - 1) * ROW_DY
            local sel = (self.focus == "panel" and i == self.cursor)
            local a   = (sel and 1 or 0.6) * fade
            self.font:print(opt.label, PANEL_LX, y, { color = { 1, 1, 1, a } })
            local vt   = self:_value_text(opt)
            local vcol = (self.capturing and self.capturing == opt.action)
                and { 1, 0.9, 0.4, fade } or { 1, 1, 1, a }
            self.font:print(vt, VALUE_RX - self.font:width(vt), y, { color = vcol })
            if sel then self:_arrow(PANEL_LX, y, fade) end
        end
    end

    -- Footer hint reflecting the current mode.
    local hint
    if self.capturing then
        hint = "PRESS A KEY   ESC CANCELS"
    elseif menu_focus then
        hint = "UP/DOWN SELECT   ENTER OPEN   ESC EXIT"
    else
        hint = "UP/DOWN MOVE   LEFT/RIGHT CHANGE   ESC BACK"
    end
    self.font:print(hint, (DESIGN_W - self.font:width(hint)) / 2, FOOTER_Y,
        { color = { 1, 1, 1, 0.5 * fade } })

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return AdvancedSettings
