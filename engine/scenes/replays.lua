-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local Scene  = require "engine.core.scene"
local Replay = require "engine.game.replay"

-- Replay browser (F4 from the overview): the testing interface for recorded runs.
-- Lists the recordings in the save directory, plays one back at normal speed, or
-- verifies one at speed by comparing its state checksums and reporting the first
-- tick that disagrees.
local Replays = Class(Scene)

local ROW_H = 18
local COLORS = {
    title  = { 0.55, 0.85, 1.00 },
    label  = { 0.72, 0.76, 0.80 },
    value  = { 0.95, 0.95, 0.75 },
    sel    = { 1.00, 0.85, 0.35 },
    ok     = { 0.55, 0.95, 0.55 },
    fail   = { 1.00, 0.45, 0.40 },
    dim    = { 0.50, 0.52, 0.55 },
}

function Replays:enter()
    self:refresh()
end

function Replays:refresh()
    self.entries = Replay.list()
    self.index   = math.min(self.index or 1, math.max(1, #self.entries))
end

function Replays:selected()
    return self.entries[self.index]
end

-- Load the world the recording was made on, hand the replay to the gameplay
-- scene, and switch to it. verify runs the simulation many ticks per frame and
-- only reports the result.
function Replays:_play(verify)
    local entry = self:selected()
    if not entry then return end
    local app    = self.app
    local replay = entry.replay
    -- The gameplay scene loads the replay's own stage on entry (reload_stage), so
    -- playback always starts from a pristine world.
    app.campaign         = false
    app.settings.loadout = nil
    app.replay_play      = replay
    app.replay_verify    = verify and true or false
    app.replay_result    = nil
    replay:rewind()
    app.scenes:switch(replay.header.mode == "coop" and "coop_gameplay" or "gameplay")
end

function Replays:update(_dt) end   -- the world behind the panel stays frozen

function Replays:keypressed(key)
    local app = self.app
    if key == "escape" or key == "f4" then app.scenes:switch("overview"); return end
    if key == "up"     then self.index = math.max(1, self.index - 1); return end
    if key == "down"   then self.index = math.min(#self.entries, self.index + 1); return end
    if key == "return" or key == "kpenter" then self:_play(false); return end
    if key == "v"      then self:_play(true); return end
    if key == "r"      then app.record_runs = not app.record_runs; return end
    if key == "delete" or key == "x" then
        local entry = self:selected()
        if entry then
            entry.replay:delete()
            self:refresh()
        end
        return
    end
end

local function header_line(replay)
    local h = replay.header
    return string.format("%s  %s  %d player%s  %d ticks  seed %s",
        h.stage or "?", h.mode or "?", tonumber(h.players) or 1,
        (tonumber(h.players) or 1) > 1 and "s" or "", replay.length, h.seed or "?")
end

function Replays:draw()
    local app = self.app
    -- The overview stays visible behind the panel.
    app.scenes:get("overview"):draw()

    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, 0.85)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    local x, y = 40, 40
    g.setColor(COLORS.title)
    g.print("REPLAYS", x, y, 0, 1.5, 1.5)
    y = y + 32

    g.setColor(COLORS.label)
    g.print("Recording new runs: ", x, y)
    g.setColor(app.record_runs and COLORS.ok or COLORS.dim)
    g.print(app.record_runs and "ON" or "OFF", x + 150, y)
    g.setColor(COLORS.dim)
    g.print("build " .. Replay.build_id(), x + 220, y)
    y = y + 28

    -- Result of the last playback, if any.
    local result = app.replay_result
    if result then
        if result.desync then
            g.setColor(COLORS.fail)
            local parts = (result.parts and #result.parts > 0)
                and (": " .. table.concat(result.parts, ", ")) or ""
            g.print(string.format("DIVERGED at tick %d (%.1f s into the run)%s",
                result.desync, result.desync / 60, parts), x, y)
        elseif result.ok then
            g.setColor(COLORS.ok)
            g.print(string.format("VERIFIED: %d ticks replayed, every checkpoint matched",
                result.length), x, y)
        else
            g.setColor(COLORS.value)
            g.print(string.format("%s at tick %d of %d, no divergence up to there",
                (result.reason or "ended"):upper(), result.tick, result.length), x, y)
        end
        y = y + 24
    end

    if #self.entries == 0 then
        g.setColor(COLORS.dim)
        g.print("No recordings yet. Play a phase with recording ON, then come back.", x, y)
    else
        for i, entry in ipairs(self.entries) do
            local selected = (i == self.index)
            g.setColor(selected and COLORS.sel or COLORS.label)
            g.print((selected and "> " or "  ") .. entry.name, x, y)
            g.setColor(selected and COLORS.value or COLORS.dim)
            g.print(header_line(entry.replay), x + 260, y)
            y = y + ROW_H
            if y > screen_h - 80 then break end
        end
    end

    g.setColor(COLORS.dim)
    g.print("[Up/Down] select   [Enter] play   [V] verify at speed   [R] toggle recording   " ..
        "[X] delete   [Esc] back", x, screen_h - 40)
    g.setColor(1, 1, 1)
end

return Replays
