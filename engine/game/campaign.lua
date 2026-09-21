-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Loadout = require "engine.game.loadout"
local Config  = require "engine.core.config"
local Score   = require "engine.game.score"
local Log     = require "engine.core.log"

-- NEW GAME run state. A solo run carries one score, lives and bonus threshold
-- on the app (run_score / run_lives / run_bonus_life) and one Loadout. A co-op
-- run (app.coop_run) carries the same per player, each with their own Loadout,
-- plus the lives rule picked in OPTIONS when the run started: "separate" spare
-- vehicles per player, or one "shared" pool (players' lives mirror it). A
-- player left without a vehicle is `out` for the rest of the run; the run is
-- over when every player is.
local Campaign = {}

Campaign.PLAYERS = 2

function Campaign.start(app, players)
    app.campaign       = true
    app.run_score      = 0
    app.run_lives      = Score.START_LIVES
    app.run_bonus_life = Score.BONUS_LIFE_STEP
    app.loadout        = Loadout:new()
    app.coop_run       = nil
    if players == Campaign.PLAYERS then
        local shared = Config.coop_lives == "shared"
        local run    = { lives_mode = shared and "shared" or "separate", players = {} }
        if shared then run.pool = Score.START_LIVES * Campaign.PLAYERS end
        for i = 1, Campaign.PLAYERS do
            run.players[i] = {
                score      = 0,
                lives      = run.pool or Score.START_LIVES,
                bonus_life = Score.BONUS_LIFE_STEP,
                out        = false,
                loadout    = Loadout:new(),
            }
        end
        app.coop_run = run
    end
    Log.info("game", "new %s campaign", app.coop_run and "co-op" or "solo")
end

-- The co-op run in progress, or nil for a solo run / no run.
function Campaign.coop(app)
    return app.campaign and app.coop_run or nil
end

-- Player numbers still in the co-op run, in order.
function Campaign.active_players(app)
    local out = {}
    local run = Campaign.coop(app)
    if not run then return out end
    for i, p in ipairs(run.players) do
        if not p.out then out[#out + 1] = i end
    end
    return out
end

-- The active player after / before `number` (nil past either end); from
-- nil, the first / last one.
function Campaign.next_player(app, number)
    for _, i in ipairs(Campaign.active_players(app)) do
        if not number or i > number then return i end
    end
    return nil
end

function Campaign.prev_player(app, number)
    local list = Campaign.active_players(app)
    for k = #list, 1, -1 do
        if not number or list[k] < number then return list[k] end
    end
    return nil
end

-- Final scores for the high-score screen: a solo run's total, or one
-- labelled entry per co-op player.
function Campaign.final_scores(app)
    local run = Campaign.coop(app)
    if not run then return app.run_score or 0 end
    local out = {}
    for i, p in ipairs(run.players) do
        out[#out + 1] = { score = p.score or 0, label = "PLAYER " .. i }
    end
    return out
end

-- The run is over (out of vehicles or the last stage cleared): hand the
-- scores to the high-score screen.
function Campaign.finish(app)
    local scores = Campaign.final_scores(app)
    app.campaign = false
    app.coop_run = nil
    app.scenes:switch("hiscores", scores)
end

-- A phase was cleared and its state carried into the run: open the next
-- phase's briefing (with the mission picture when a new mission begins), or
-- finish the run after the last stage. The next stage follows the loaded
-- stage's name, not world.stage_index, which the overview's stage picker moves
-- without loading anything.
function Campaign.advance(app)
    local world = app.world
    local next_stage
    for i, name in ipairs(world.stages) do
        if name == world.stage_name then next_stage = world.stages[i + 1] end
    end
    if not next_stage then
        Log.info("game", "campaign complete")
        Campaign.finish(app)
        return
    end
    local cur_m  = tonumber((world.stage_name or ""):match("^stage(%d)"))
    local next_m = tonumber(next_stage:match("^stage(%d)"))
    Log.info("game", "campaign continues to %s", next_stage)
    world:load(next_stage)
    app.after_stage_load()
    app.scenes:switch("mission_briefing", next_stage)
    if next_m and next_m ~= cur_m then
        app.screen:show_mission(next_m)
    end
end

return Campaign
