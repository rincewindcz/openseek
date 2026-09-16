-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json = require "lib.json"
local Log  = require "engine.core.log"

-- Central rebindable key map for the single-player gameplay actions and global
-- shortcuts (screenshot). Each action maps to a list of keys; any of them held (or
-- pressed) triggers it, so the stock defaults keep both the WASD and arrow bindings. The advanced options CONTROLS
-- page edits this live; it is persisted to the save directory. Co-op keeps its own
-- per-player key sets (engine/scenes/coop_gameplay.lua) and does not use this map.
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
    screenshot = { "f12" },
}

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
}

Input.map = {}

local function copy_keys(list)
    local t = {}
    for i, k in ipairs(list) do t[i] = k end
    return t
end

-- Restore every action to its stock binding.
function Input.reset()
    Input.map = {}
    for action, keys in pairs(DEFAULTS) do
        Input.map[action] = copy_keys(keys)
    end
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
            local keys = {}
            for _, k in ipairs(v) do
                if type(k) == "string" then keys[#keys + 1] = k end
            end
            if #keys > 0 then Input.map[action] = keys end
        elseif type(v) == "string" then
            Input.map[action] = { v }
        end
    end
end

local function json_string(s)
    return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
        local esc = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                      ['\r'] = '\\r', ['\t'] = '\\t' }
        return esc[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
end

-- Persist the current bindings (the bundled json module decodes but does not
-- encode, so the object is emitted directly).
function Input.save()
    local parts = {}
    for _, a in ipairs(Input.ACTIONS) do
        local keys = Input.map[a.key] or {}
        local encoded = {}
        for i, k in ipairs(keys) do encoded[i] = json_string(k) end
        parts[#parts + 1] = string.format('  "%s": [%s]', a.key, table.concat(encoded, ", "))
    end
    local body = "{\n" .. table.concat(parts, ",\n") .. "\n}\n"
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

-- True if a keypressed event key is bound to the action.
function Input.pressed(action, key)
    local keys = Input.map[action]
    if not keys then return false end
    for _, k in ipairs(keys) do
        if k == key then return true end
    end
    return false
end

-- The key bound in a slot (1 = primary, 2 = secondary), or nil.
function Input.key_at(action, slot)
    local keys = Input.map[action]
    return keys and keys[slot] or nil
end

-- Column text for a key, or "---" for an empty slot.
function Input.key_label(key)
    if not key then return "---" end
    return KEY_NAMES[key] or key:upper():sub(1, 5)
end

-- Bind key into one slot of an action. The key is dropped from the action's
-- other slot first, so it is never listed twice; binding into the empty second
-- slot of an unbound action fills the first.
function Input.rebind(action, key, slot)
    local keys = Input.map[action] or {}
    for i = #keys, 1, -1 do
        if keys[i] == key then table.remove(keys, i) end
    end
    slot = math.min(slot or 1, #keys + 1, Input.MAX_KEYS)
    keys[slot] = key
    Input.map[action] = keys
end

-- Clear one slot. The last key of an action stays: an action with no key left
-- could not be triggered, and the page has no way to get back to it.
function Input.clear(action, slot)
    local keys = Input.map[action]
    if not keys or #keys < 2 or not keys[slot] then return false end
    table.remove(keys, slot)
    return true
end

return Input
