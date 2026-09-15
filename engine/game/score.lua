-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

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

-- Phase-end bonus per unit of each debriefing line. The line values shown on
-- screen are percentages for the first two lines; the score always uses the raw
-- counts behind them.
Score.PHASE_POINTS = {
    ground    = 50,    -- tanks, turrets, flak, soldiers destroyed
    buildings = 20,    -- structures and trucks destroyed
    choppers  = 200,   -- enemy helicopters shot down
    rescues   = 120,   -- personnel brought home
    ok        = 200,   -- OK rating (provisional)
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
        p.next_bonus_life = p.next_bonus_life + Score.BONUS_LIFE_STEP
    end
end

-- Weighted phase-end bonus for one debriefing line.
function Score.line_bonus(kind, count)
    return (Score.PHASE_POINTS[kind] or 0) * (count or 0)
end

return Score
