-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Config     = require "engine.core.config"
local Input      = require "engine.core.input"
local InputFrame = require "engine.core.input_frame"
local Gamepad    = require "engine.core.gamepad"
local Hint       = require "engine.ui.hint"

-- EXTRA (control_hints): the controls a new player does not find on their own,
-- named for the first seconds after a vehicle enters a single-player phase,
-- each until the player has used it once: fire, the weapon switch and, in the
-- chopper, landing. The actions used so far persist in Config.hints_learned.
-- A last line names the key that dismisses them all for good (DISMISS_KEY,
-- DISMISS_BUTTON on a pad), which counts every action as used.
-- Presentation only: it reads the tick's input frame and the simulation clock
-- and never writes the simulation.
local ControlHints = Class()

local SHOW_TIME = 12    -- seconds of phase time the hints stay up after a vehicle enters
local FADE_TIME = 0.8   -- seconds a hint takes to fade, at the end or once its action is used
local SCALE     = 2
local LINE_GAP  = 6
local TOP       = 0.34  -- of the screen height: above the vehicle, under a map's objective line
local NOTE_GAP  = 4     -- extra space above the dismiss line
local NOTE_DIM  = 0.7   -- the dismiss line's alpha against the hints'

-- The key and pad button that dismiss the hints, fixed like the menu button.
-- The key is the one under Esc, whatever it types on the layout in use.
local DISMISS_SCANCODE      = "`"
ControlHints.DISMISS_BUTTON = "rightstick"
local DISMISS_LABELS = { keys = "~", pad = "RS" }

-- In display order. A vehicle limits a hint to that vehicle; the weapon switch
-- is only named when there is more than one weapon to switch to.
local HINTS = {
    { action = "fire",    label = "FIRE" },
    { action = "weapon",  label = "SWITCH WEAPON" },
    { action = "takeoff", label = "LAND", vehicle = "chopper" },
}

-- Full names for the keys the CONTROLS page shortens to fit its columns.
local KEY_NAMES = {
    lctrl = "CTRL", rctrl = "CTRL", lshift = "SHIFT", rshift = "SHIFT",
    lalt = "ALT", ralt = "ALT", space = "SPACE", ["return"] = "ENTER",
    kpenter = "ENTER", backspace = "BACKSPACE",
}

local function parse(text)
    local out = {}
    for action in tostring(text or ""):gmatch("[^,]+") do out[action] = true end
    return out
end

function ControlHints:init()
    self.learned = {}
    self.gone    = {}      -- action -> phase time it was used this showing
    self.device  = Gamepad.count() > 0 and "pad" or "keys"
    self.dirty   = false
end

-- A vehicle enters the phase (spawn or respawn) at phase time `time`.
-- switchable: it carries more than one weapon.
function ControlHints:start(player, time, switchable)
    self.player     = player
    self.since      = time
    self.switchable = switchable
    self.learned    = parse(Config.hints_learned)
    self.gone       = {}
end

-- The device the player last touched ("keys" / "pad"), whose bindings are named.
function ControlHints:use(device)
    self.device = device
end

function ControlHints:_learn(action, time)
    if self.learned[action] then return end
    self.learned[action] = true
    self.gone[action]    = time
    self.dirty           = true
    local list = {}
    for _, hint in ipairs(HINTS) do
        if self.learned[hint.action] then list[#list + 1] = hint.action end
    end
    Config.hints_learned = table.concat(list, ",")
end

function ControlHints.is_dismiss_key(key)
    return key == "`" or key == love.keyboard.getKeyFromScancode(DISMISS_SCANCODE)
end

-- The dismiss key at phase time `time`: while hints are up, every action
-- counts as used and they fade out. Returns true when it was taken.
function ControlHints:dismiss(time)
    if #self:_shown(time) == 0 then return false end
    for _, hint in ipairs(HINTS) do self:_learn(hint.action, time) end
    return true
end

-- A tick's input frame of the player, at phase time `time`.
function ControlHints:observe(frame, time)
    if not (Config.control_hints and frame) then return end
    if InputFrame.held(frame, "fire") then self:_learn("fire", time) end
    for _, event in ipairs(frame.events) do
        if event == "weapon" or event:match("^slot:") then
            self:_learn("weapon", time)
        elseif event == "takeoff" then
            self:_learn("takeoff", time)
        end
    end
end

-- Write what was learned to the settings file. Called once the phase has let go of
-- its simulation parameters (Replay.Hold), so the saved settings are the
-- player's own.
function ControlHints:save()
    if not self.dirty then return end
    Config.save()
    self.dirty = false
end

function ControlHints:_key(action)
    local key = Input.key_at(action, 1, self.device)
    if not key then return nil end
    return KEY_NAMES[key] or Input.key_label(key)
end

-- The hints up at phase time `time`, in display order: { text, alpha }.
function ControlHints:_shown(time)
    local out = {}
    local p   = self.player
    if not (Config.control_hints and p and self.since) or p.death then return out end
    local left = SHOW_TIME - (time - self.since)
    if left <= 0 then return out end
    for _, hint in ipairs(HINTS) do
        local key   = self:_key(hint.action)
        local shown = key and (not hint.vehicle or hint.vehicle == p.vehicle)
            and (hint.action ~= "weapon" or self.switchable)
        local alpha = math.min(1, left / FADE_TIME)
        if self.learned[hint.action] then
            local used = self.gone[hint.action]
            alpha = used and math.min(alpha, 1 - (time - used) / FADE_TIME) or 0
        end
        if shown and alpha > 0 then
            out[#out + 1] = { text = "{" .. key .. "}  " .. hint.label, alpha = alpha }
        end
    end
    return out
end

-- The hints still to show at phase time `time`, in the HUD's font, and under
-- them the dismiss key as brightly as the brightest of them.
function ControlHints:draw(font, time)
    local shown = self:_shown(time)
    if #shown == 0 then return end
    local screen_w, screen_h = love.graphics.getDimensions()
    local y    = screen_h * TOP
    local note = 0
    for _, line in ipairs(shown) do
        Hint.print_centered(font, line.text, screen_w, y,
            { scale = SCALE, alpha = line.alpha, shadow = true, raw = true })
        y    = y + font.line_height * SCALE + LINE_GAP
        note = math.max(note, line.alpha)
    end
    Hint.print_centered(font, "{" .. DISMISS_LABELS[self.device] .. "}  HIDE THESE TIPS", screen_w,
        y + NOTE_GAP, { alpha = note * NOTE_DIM, shadow = true, raw = true })
    love.graphics.setColor(1, 1, 1)
end

return ControlHints
