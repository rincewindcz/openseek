-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Log = require "engine.core.log"

-- Scoring rules, ported from the original. Points arrive in
-- two streams: every destroyed entity is worth its class hit_points the moment it
-- dies, and a completed phase credits a weighted tally of what was destroyed and
-- rescued. Every credit runs the bonus-life ladder.
--
-- The original keeps one global score; the port splits score, lives and the
-- destruction columns per player, so all of this works on a player table.
local Score = {}

-- A bonus vehicle every 15000 points, cumulative (the threshold keeps climbing
-- past the cap, so a capped run does not bank lives it never earned).
Score.BONUS_LIFE_STEP = 15000
Score.MAX_LIVES       = 9
Score.START_LIVES     = 3

-- Phase-end bonus per unit of each debriefing line. The unit is whatever the
-- line puts on screen, not what is behind it: the original's tally animation
-- walks the printed readout down to zero and books one weight per step
-- (0x206334 onward), so the first two lines pay per percentage point and a
-- cleared stage is worth a flat 5000 + 2000 however much it held.
Score.PHASE_POINTS = {
    ground    = 50,    -- per percent of ground forces destroyed
    buildings = 20,    -- per percent of buildings destroyed
    choppers  = 200,   -- per enemy helicopter shot down
    rescues   = 120,   -- per person brought home
    ok        = 200,   -- per OK badge earned
}

-- Cap the life counter wherever lives are handed out.
function Score.grant_life(p)
    if (p.lives or 0) < Score.MAX_LIVES then p.lives = (p.lives or 0) + 1 end
end

-- Credit points to a player and hand out any bonus lives they cross. Every score
-- credit goes through here so the ladder can never be skipped.
function Score.award(p, points)
    if not p or not points or points == 0 then return end
    p.score           = (p.score or 0) + points
    p.next_bonus_life = p.next_bonus_life or Score.BONUS_LIFE_STEP
    while p.score >= p.next_bonus_life do
        Score.grant_life(p)
        Log.info("score", "P%d bonus vehicle at %d points, %d lives", p.index or 1, p.next_bonus_life, p.lives)
        p.next_bonus_life = p.next_bonus_life + Score.BONUS_LIFE_STEP
    end
end

-- Weighted phase-end bonus for one debriefing line.
function Score.line_bonus(kind, count)
    return (Score.PHASE_POINTS[kind] or 0) * (count or 0)
end

-- Percentage readout of the first two debriefing lines. The original clamps the
-- count to the stage total, then divides in 1/512 fixed point and truncates
-- twice (0x205aaa); since the line is paid per printed percent, the truncation
-- is a score input and has to be reproduced exactly.
function Score.percent(killed, total)
    if not total or total <= 0 then return 0 end
    local k = math.min(killed or 0, total)
    return math.min(100, math.floor(math.floor(k * 512 / total) * 100 / 512))
end

-- The chopper line shortens its count-down for big tallies: above 10 / 20 / 40
-- kills the readout is halved, quartered or eighthed and each step is worth the
-- matching multiple of 200 (0x205a2d, 0x206460). Returns the printed value and
-- the points one step of it carries, so the credit truncates with the readout.
function Score.chopper_tier(count)
    local c = count or 0
    local step = 1
    if c > 10 then step = 2 end
    if c > 20 then step = 4 end
    if c > 40 then step = 8 end
    return math.floor(c / step), Score.PHASE_POINTS.choppers * step
end

return Score
