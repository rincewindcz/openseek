-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json    = require "lib.json"
local Loadout = require "engine.game.loadout"
local Score   = require "engine.game.score"
local Log     = require "engine.core.log"

-- Campaign save slots. A slot is one JSON file in the save directory holding
-- everything a run carries between phases: the stage it is parked on, the
-- running score, the spare vehicles and the next bonus-vehicle threshold, and
-- the whole weapon inventory (medals, owned levels, bay loadout, special and
-- vehicle characteristics). There is no slot limit; the player names each one
-- on the SAVE / LOAD screen (engine/scenes/saves.lua).
--
-- A save is taken on the mission briefing, which is the one point where the run
-- is between phases and its state is final, so loading one restores the run and
-- reopens that briefing. A co-op run adds a `coop` table: the lives rule and
-- pool, each player's score, lives, threshold, out flag, inventory and
-- vehicle variants (engine/game/campaign.lua).
local Savegame = {}

Savegame.DIR     = "saves"
Savegame.VERSION = 1

local function capture_coop(app)
    local run = app.campaign and app.coop_run
    if not run then return nil end
    local coop    = app.settings.coop or {}
    local players = {}
    for i, p in ipairs(run.players) do
        players[i] = {
            score        = p.score,
            lives        = p.lives,
            bonus_life   = p.bonus_life,
            out          = p.out,
            loadout      = p.loadout:snapshot(),
            chopper_skin = (coop.chopper_skin or {})[i] or 1,
            tank_skin    = (coop.tank_skin or {})[i] or 1,
        }
    end
    return { lives_mode = run.lives_mode, pool = run.pool, players = players }
end

local function apply_coop(app, data)
    local run = { lives_mode = data.lives_mode == "shared" and "shared" or "separate",
                  pool = tonumber(data.pool), players = {} }
    local coop = app.settings.coop
    for i, p in ipairs(data.players or {}) do
        run.players[i] = {
            score      = tonumber(p.score) or 0,
            lives      = tonumber(p.lives) or Score.START_LIVES,
            bonus_life = tonumber(p.bonus_life) or Score.BONUS_LIFE_STEP,
            out        = p.out == true,
            loadout    = Loadout.restore(p.loadout),
        }
        if coop then
            coop.chopper_skin[i] = tonumber(p.chopper_skin) or 1
            coop.tank_skin[i]    = tonumber(p.tank_skin) or 1
        end
    end
    if run.lives_mode == "shared" and not run.pool then run.pool = Score.START_LIVES end
    return run
end

-- The state a run carries, as a plain table. `name` is the player's slot label.
function Savegame.capture(app, name)
    local loadout = Loadout.active(app)
    return {
        version    = Savegame.VERSION,
        name       = name,
        stage      = app.world.stage_name,
        campaign   = app.campaign and true or false,
        score      = app.run_score or 0,
        lives      = app.run_lives or Score.START_LIVES,
        bonus_life = app.run_bonus_life or Score.BONUS_LIFE_STEP,
        vehicle    = loadout.vehicle,
        loadout    = loadout:snapshot(),
        coop       = capture_coop(app),
        time       = os.time(),
        saved_at   = os.date("%Y-%m-%d %H:%M"),
    }
end

-- Restore a run into the app context. The caller loads the stage and opens the
-- briefing; this only rebuilds the state those steps read.
function Savegame.apply(app, data)
    if type(data) ~= "table" or not data.stage then return false end
    app.campaign       = data.campaign ~= false
    app.run_score      = tonumber(data.score) or 0
    app.run_lives      = tonumber(data.lives) or Score.START_LIVES
    app.run_bonus_life = tonumber(data.bonus_life) or Score.BONUS_LIFE_STEP
    app.coop_run       = nil
    if app.campaign and type(data.coop) == "table" then app.coop_run = apply_coop(app, data.coop) end
    local loadout      = Loadout.restore(data.loadout)
    if app.campaign then
        app.loadout = loadout
    else
        app.loadout_free = loadout
    end
    app.settings.vehicle = data.vehicle or loadout.vehicle
    app.settings.loadout = nil   -- rebuilt when the equip screen confirms
    app.replay_play      = nil
    return true
end

-- File names carry the wall clock and a fixed-width counter, so sorting them
-- lexicographically orders slots written within the same second correctly.
local function path_for(time)
    local stamp = os.date("%Y%m%d-%H%M%S", time)
    local n = 1
    local path
    repeat
        path = string.format("%s/save-%s-%02d.json", Savegame.DIR, stamp, n)
        n = n + 1
    until not love.filesystem.getInfo(path)
    return path
end

-- Write a captured table to `path` (a new slot file when omitted). Returns the
-- path written, or nil.
function Savegame.write(data, path)
    love.filesystem.createDirectory(Savegame.DIR)
    path = path or path_for(data.time)
    local ok, err = pcall(love.filesystem.write, path, json.encode(data) .. "\n")
    if not ok then
        Log.warn("savegame", "cannot write %s: %s", path, tostring(err))
        return nil
    end
    Log.info("savegame", "saved %s to %s", data.name or "?", path)
    return path
end

function Savegame.read(path)
    local raw = love.filesystem.getInfo(path) and love.filesystem.read(path)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" or not data.stage then
        Log.warn("savegame", "ignoring unreadable %s", path)
        return nil
    end
    return data
end

-- Every readable slot, newest first.
function Savegame.list()
    local out = {}
    if not love.filesystem.getInfo(Savegame.DIR) then return out end
    for _, name in ipairs(love.filesystem.getDirectoryItems(Savegame.DIR)) do
        if name:match("%.json$") then
            local path = Savegame.DIR .. "/" .. name
            local data = Savegame.read(path)
            if data then out[#out + 1] = { path = path, data = data } end
        end
    end
    table.sort(out, function(a, b)
        local ta, tb = tonumber(a.data.time) or 0, tonumber(b.data.time) or 0
        if ta ~= tb then return ta > tb end
        return a.path > b.path
    end)
    return out
end

-- Cheaper than list() for the main menu, which only needs to know whether the
-- LOAD entry is worth enabling.
function Savegame.any()
    if not love.filesystem.getInfo(Savegame.DIR) then return false end
    for _, name in ipairs(love.filesystem.getDirectoryItems(Savegame.DIR)) do
        if name:match("%.json$") then return true end
    end
    return false
end

function Savegame.delete(path)
    Log.info("savegame", "deleted %s", path)
    love.filesystem.remove(path)
end

-- A stageMP name as the mission and phase numbers the screens show, both
-- 1-based (stage00 is MISSION 1 PHASE 1).
local function mission_phase(stage)
    local m = tonumber((stage or ""):sub(6, 6))
    local p = tonumber((stage or ""):sub(7, 7))
    if not (m and p) then return nil end
    return m + 1, p + 1
end

function Savegame.stage_label(stage)
    local m, p = mission_phase(stage)
    if not m then return stage or "?" end
    return string.format("MISSION %d PHASE %d", m, p)
end

function Savegame.stage_short(stage)
    local m, p = mission_phase(stage)
    if not m then return stage or "?" end
    return string.format("M%d P%d", m, p)
end

return Savegame
