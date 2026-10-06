-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json = require "lib.json"
local Log  = require "engine.core.log"

-- Central rebindable maps for the gameplay actions and global shortcuts
-- (screenshot), one per device: "keys" (Input.map, the keyboard) and "pad"
-- (Input.pad_map, gamepad buttons, see engine/core/gamepad.lua). Each action maps
-- to a list of keys or buttons; any of them held (or pressed) triggers it, so the
-- stock defaults keep both the WASD and arrow bindings. The advanced options
-- CONTROLS page edits both live; they are persisted to the save directory. Co-op
-- keeps its own per-player key sets (engine/scenes/coop_gameplay.lua) and shares
-- the gamepad map, each player on their own pad.
local Input = {}

local SAVE_PATH = "data/keybinds.json"

-- Stock bindings. up/down/left/right/modifier feed Player:_held (movement is read
-- from the player's controls table, which the gameplay scene points here); the
-- rest are matched against keypressed events in the gameplay scene.
local DEFAULTS = {
    up         = { "w", "up" },
    down       = { "s", "down" },
    left       = { "a", "left" },
    right      = { "d", "right" },
    modifier   = { "lshift", "rshift" },
    fire       = { "lctrl", "rctrl" },
    takeoff    = { "space", "f" },
    weapon     = { "q" },
    pause      = { "p" },
    radar_zoom = { "f9" },
    screenshot = { "f12" },
}

-- Stock gamepad buttons, by their LOVE GamepadButton name plus "triggerleft" /
-- "triggerright" (the triggers read as buttons). The left stick always steers
-- and the right stick always strafes; START opens the menu. An action may be
-- left without a button.
local PAD_DEFAULTS = {
    up         = { "dpup" },
    down       = { "dpdown" },
    left       = { "dpleft" },
    right      = { "dpright" },
    modifier   = { "leftshoulder", "triggerleft" },
    fire       = { "a", "triggerright" },
    takeoff    = { "b" },
    weapon     = { "y", "rightshoulder" },
    pause      = { "back" },
    radar_zoom = { "x" },
    screenshot = {},
}

Input.DEVICES = { "keys", "pad" }

-- Keys bindable per action: a primary and an optional secondary, the two
-- columns of the CONTROLS page.
Input.MAX_KEYS = 2

-- Display order and labels for the CONTROLS page. The labels are kept short so
-- a row fits its label and both key columns across the 320px design width.
Input.ACTIONS = {
    { key = "up",         label = "MOVE UP" },
    { key = "down",       label = "MOVE DOWN" },
    { key = "left",       label = "TURN LEFT" },
    { key = "right",      label = "TURN RIGHT" },
    { key = "modifier",   label = "STRAFE" },
    { key = "fire",       label = "FIRE" },
    { key = "takeoff",    label = "TAKEOFF" },
    { key = "weapon",     label = "WEAPON" },
    { key = "pause",      label = "PAUSE" },
    { key = "radar_zoom", label = "RADAR ZOOM" },
    { key = "screenshot", label = "SNAPSHOT" },
}

-- Short names for the keys whose LOVE name does not fit a key column; anything
-- else is upper-cased and cut to the column width.
local KEY_NAMES = {
    lshift = "LSH",  rshift = "RSH",  lctrl   = "LCTL", rctrl    = "RCTL",
    lalt   = "LALT", ralt   = "RALT", lgui    = "LGUI", rgui     = "RGUI",
    space  = "SPC",  ["return"] = "ENT", kpenter = "KENT", escape = "ESC",
    backspace = "BSP", delete = "DEL", capslock = "CAPS",
    pageup = "PGUP", pagedown = "PGDN", printscreen = "PRSC",
    leftshoulder = "LB", rightshoulder = "RB", triggerleft = "LT", triggerright = "RT",
    leftstick = "LS", rightstick = "RS", guide = "GUIDE",
    dpup = "D-UP", dpdown = "D-DN", dpleft = "D-LT", dpright = "D-RT",
}

Input.map     = {}
Input.pad_map = {}

local function copy_keys(list)
    local t = {}
    for i, k in ipairs(list) do t[i] = k end
    return t
end

local function map_for(device)
    return device == "pad" and Input.pad_map or Input.map
end

-- Restore every action of a device ("keys" / "pad", both when omitted) to its
-- stock binding.
function Input.reset(device)
    if device ~= "pad" then
        Input.map = {}
        for action, keys in pairs(DEFAULTS) do Input.map[action] = copy_keys(keys) end
    end
    if device ~= "keys" then
        Input.pad_map = {}
        for action, buttons in pairs(PAD_DEFAULTS) do Input.pad_map[action] = copy_keys(buttons) end
    end
end

-- The strings of a decoded JSON list.
local function string_list(v)
    local out = {}
    for _, k in ipairs(v) do
        if type(k) == "string" then out[#out + 1] = k end
    end
    return out
end

-- Overlay any saved bindings onto the defaults. Called once at startup.
function Input.load()
    Input.reset()
    if not love.filesystem.getInfo(SAVE_PATH) then return end
    local raw = love.filesystem.read(SAVE_PATH)
    if not raw then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then
        Log.warn("input", "ignoring unreadable %s", SAVE_PATH)
        return
    end
    for action in pairs(DEFAULTS) do
        local v = data[action]
        if type(v) == "table" then
            local keys = string_list(v)
            if #keys > 0 then Input.map[action] = keys end
        elseif type(v) == "string" then
            Input.map[action] = { v }
        end
    end
    -- Gamepad bindings sit under "pad"; a saved empty list is a cleared action.
    local pad = type(data.pad) == "table" and data.pad or {}
    for action in pairs(PAD_DEFAULTS) do
        if type(pad[action]) == "table" then Input.pad_map[action] = string_list(pad[action]) end
    end
end

local function json_string(s)
    return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
        local esc = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                      ['\r'] = '\\r', ['\t'] = '\\t' }
        return esc[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
end

-- One `"action": [...]` line per action of a device map.
local function encode_map(map, indent)
    local parts = {}
    for _, a in ipairs(Input.ACTIONS) do
        local encoded = {}
        for i, k in ipairs(map[a.key] or {}) do encoded[i] = json_string(k) end
        parts[#parts + 1] = string.format('%s"%s": [%s]', indent, a.key, table.concat(encoded, ", "))
    end
    return table.concat(parts, ",\n")
end

-- Persist the current bindings: the keyboard actions at the top level, the
-- gamepad ones under "pad" (the object is emitted directly, like the settings).
function Input.save()
    local body = "{\n" .. encode_map(Input.map, "  ") .. ',\n  "pad": {\n'
        .. encode_map(Input.pad_map, "    ") .. "\n  }\n}\n"
    local dir  = SAVE_PATH:match("^(.*)/[^/]+$")
    if dir then love.filesystem.createDirectory(dir) end
    local ok, written = pcall(love.filesystem.write, SAVE_PATH, body)
    if ok and written then
        Log.info("input", "saved %s", SAVE_PATH)
    else
        Log.warn("input", "cannot write %s", SAVE_PATH)
    end
end

-- True if any key bound to the action is currently held.
function Input.held(action)
    local keys = Input.map[action]
    if not keys then return false end
    for _, k in ipairs(keys) do
        if love.keyboard.isDown(k) then return true end
    end
    return false
end

-- True if a pressed key (or, with device "pad", a gamepad button) is bound to
-- the action.
function Input.pressed(action, key, device)
    local keys = map_for(device)[action]
    if not keys then return false end
    for _, k in ipairs(keys) do
        if k == key then return true end
    end
    return false
end

-- The key or button bound in a slot (1 = primary, 2 = secondary), or nil.
function Input.key_at(action, slot, device)
    local keys = map_for(device)[action]
    return keys and keys[slot] or nil
end

-- Column text for a key or gamepad button, or "---" for an empty slot.
function Input.key_label(key)
    if not key then return "---" end
    return KEY_NAMES[key] or key:upper():sub(1, 5)
end

-- Bind key into one slot of an action. The key is dropped from the action's
-- other slot first, so it is never listed twice; binding into the empty second
-- slot of an unbound action fills the first.
function Input.rebind(action, key, slot, device)
    local map  = map_for(device)
    local keys = map[action] or {}
    for i = #keys, 1, -1 do
        if keys[i] == key then table.remove(keys, i) end
    end
    slot = math.min(slot or 1, #keys + 1, Input.MAX_KEYS)
    keys[slot] = key
    map[action] = keys
end

-- Clear one slot. The last key of a keyboard action stays: an action with no
-- key left could not be triggered, and the page has no way to get back to it.
-- A gamepad action may be emptied, the keyboard still reaches it.
function Input.clear(action, slot, device)
    local keys = map_for(device)[action]
    if not keys or not keys[slot] then return false end
    if device ~= "pad" and #keys < 2 then return false end
    table.remove(keys, slot)
    return true
end

return Input
