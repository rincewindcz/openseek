-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json       = require "lib.json"
local Log        = require "engine.core.log"
local Difficulty = require "engine.game.difficulty"

-- The records of the player-made maps, kept on this machine: per map, per
-- difficulty and per way of playing it ("single", "coop") the fastest win,
-- the highest score of a win, and the recording of the fastest one.
-- records/maps.json holds
--   { <map file name> = { hash, ["single-medium"] = { time, score, replay }, ... } }
-- and records/<map>-<mode>-<level>.osr the recordings. The level is the
-- difficulty preset the run was played on ("custom" when it matches none), or
-- "map" on a map that sets its own. A record belongs to the map as its file
-- stood (hash, MapFile.hash): once the map is changed its records no longer
-- count, and the first win on the new one starts them over.
local Records = {}

Records.DIR   = "records"
Records.MODES = { "single", "coop" }
Records.OWN   = "map"

local FILE = Records.DIR .. "/maps.json"

local data

local function load()
    if data then return data end
    local raw = love.filesystem.getInfo(FILE) and love.filesystem.read(FILE)
    local ok, decoded = pcall(json.decode, raw or "{}")
    data = ok and type(decoded) == "table" and decoded or {}
    return data
end

local function store()
    love.filesystem.createDirectory(Records.DIR)
    local ok, err = pcall(love.filesystem.write, FILE, json.encode(data))
    if not ok or err == false then Log.warn("records", "cannot write %s: %s", FILE, tostring(err)) end
end

local function key_of(mode, level)
    return mode .. "-" .. level
end

function Records.replay_path(name, key)
    return string.format("%s/%s-%s.osr", Records.DIR, name, key)
end

local function drop_replays(name, entry)
    if type(entry) ~= "table" then return end
    for key, v in pairs(entry) do
        if type(v) == "table" then love.filesystem.remove(Records.replay_path(name, key)) end
    end
end

-- The level records of a map are kept under: the map's own difficulty
-- (`own`, the map's "difficulty" field) or the preset `params` match (the
-- player's own parameters when nil).
function Records.level(own, params)
    return own and Records.OWN or Difficulty.match_preset(params)
end

-- The records of the map `name` as its file stands (hash) on a level:
-- { single = { time, score, replay }, coop = ... }, a mode absent until the
-- map is won that way.
function Records.of(name, hash, level)
    local entry = load()[name]
    if type(entry) ~= "table" or entry.hash ~= hash then return {} end
    local out = {}
    for _, mode in ipairs(Records.MODES) do
        local best = entry[key_of(mode, level)]
        if type(best) == "table" then out[mode] = best end
    end
    return out
end

-- The path of the recording kept for the fastest win of a mode on a level, or nil.
function Records.replay(name, hash, mode, level)
    local best = Records.of(name, hash, level)[mode]
    local path = Records.replay_path(name, key_of(mode, level))
    return best and best.replay and love.filesystem.getInfo(path) and path or nil
end

-- A win of `seconds` with `score` on the map as its file stands, played on
-- `level`. recording is the run's replay text, kept when the run is the
-- fastest. Returns what it beat, { time = bool, score = bool }, or nil when
-- it beat nothing.
function Records.submit(name, hash, mode, level, seconds, score, recording)
    local all   = load()
    local entry = all[name]
    if type(entry) ~= "table" or entry.hash ~= hash then
        drop_replays(name, entry)
        entry     = { hash = hash }
        all[name] = entry
    end
    local key  = key_of(mode, level)
    local best = type(entry[key]) == "table" and entry[key] or {}
    local beat = { time = not best.time or seconds < best.time, score = not best.score or score > best.score }
    if not (beat.time or beat.score) then return nil end
    if beat.score then best.score = score end
    if beat.time then
        best.time = math.floor(seconds * 100 + 0.5) / 100
        love.filesystem.createDirectory(Records.DIR)
        local ok, err = pcall(love.filesystem.write, Records.replay_path(name, key), recording)
        best.replay = ok and err ~= false
    end
    entry[key] = best
    store()
    Log.info("records", "%s %s: %.2f s, %d points", name, key, best.time, best.score)
    return beat
end

-- A map was erased: so are its records.
function Records.forget(name)
    local all = load()
    drop_replays(name, all[name])
    if all[name] ~= nil then
        all[name] = nil
        store()
    end
end

-- Seconds as a clock of minutes, seconds and hundredths: 2:31:40. No full
-- stop, which the menu fonts draw wide.
function Records.clock(seconds)
    local hundredths = math.floor(seconds * 100 + 0.5)
    return string.format("%d:%02d:%02d", math.floor(hundredths / 6000), math.floor(hundredths / 100) % 60,
        hundredths % 100)
end

return Records
