-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json = require "lib.json"
local Log  = require "engine.core.log"

-- The records of the player-made maps, kept on this machine: per map and per
-- way of playing it ("single", "coop") the fastest win, the highest score of
-- a win, and the recording of the fastest one. records/maps.json holds
--   { <map file name> = { hash, single = { time, score, replay }, coop = ... } }
-- and records/<map>-<mode>.osr the recordings. A record belongs to the map as
-- its file stood (hash, MapFile.hash): once the map is changed its records no
-- longer count, and the first win on the new one starts them over.
local Records = {}

Records.DIR   = "records"
Records.MODES = { "single", "coop" }

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

function Records.replay_path(name, mode)
    return string.format("%s/%s-%s.osr", Records.DIR, name, mode)
end

local function drop_replays(name)
    for _, mode in ipairs(Records.MODES) do love.filesystem.remove(Records.replay_path(name, mode)) end
end

-- The records of the map `name` as its file stands (hash): { single = { time,
-- score, replay }, coop = ... }, a mode absent until the map is won that way.
function Records.of(name, hash)
    local entry = load()[name]
    if type(entry) ~= "table" or entry.hash ~= hash then return {} end
    return entry
end

-- The path of the recording kept for a mode's fastest win, or nil.
function Records.replay(name, hash, mode)
    local best = Records.of(name, hash)[mode]
    local path = Records.replay_path(name, mode)
    return best and best.replay and love.filesystem.getInfo(path) and path or nil
end

-- A win of `seconds` with `score` on the map as its file stands. recording is
-- the run's replay text, kept when the run is the fastest; nil for a run that
-- was not recorded. Returns what it beat, { time = bool, score = bool }, or
-- nil when it beat nothing.
function Records.submit(name, hash, mode, seconds, score, recording)
    local all   = load()
    local entry = all[name]
    if type(entry) ~= "table" or entry.hash ~= hash then
        drop_replays(name)
        entry     = { hash = hash }
        all[name] = entry
    end
    local best = type(entry[mode]) == "table" and entry[mode] or {}
    local beat = { time = not best.time or seconds < best.time, score = not best.score or score > best.score }
    if not (beat.time or beat.score) then return nil end
    if beat.score then best.score = score end
    if beat.time then
        best.time   = math.floor(seconds * 100 + 0.5) / 100
        best.replay = false
        love.filesystem.createDirectory(Records.DIR)
        local path = Records.replay_path(name, mode)
        if recording then
            local ok, err = pcall(love.filesystem.write, path, recording)
            best.replay = ok and err ~= false
        else
            love.filesystem.remove(path)
        end
    end
    entry[mode] = best
    store()
    Log.info("records", "%s %s: %.2f s, %d points", name, mode, best.time, best.score)
    return beat
end

-- A map was erased: so are its records.
function Records.forget(name)
    local all = load()
    drop_replays(name)
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
