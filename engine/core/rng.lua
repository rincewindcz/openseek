-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"

-- Seeded random number generator for the simulation. Everything the simulation
-- rolls (damage smoke, debris, pickup kinds, enemy spawns, POW counts) draws from
-- one of these, created per phase from a recorded seed, so a run replays exactly.
-- Presentation code (draw functions and the weather overlay) keeps the global
-- math.random: it may draw a different number of times per frame, and must never
-- move the simulation stream.
--
-- draws counts the numbers taken, which the replay checksum folds in: two runs
-- that have consumed a different amount of randomness diverge even when the
-- visible state still matches.
local Rng = Class()

function Rng:init(seed)
    self.seed  = seed or 0
    self.gen   = love.math.newRandomGenerator(self.seed)
    self.draws = 0
end

-- Same contract as math.random: (), (m) -> 1..m, (m, n) -> m..n.
function Rng:random(m, n)
    self.draws = self.draws + 1
    if m == nil then return self.gen:random() end
    if n == nil then return self.gen:random(m) end
    return self.gen:random(m, n)
end

-- A fresh seed for a run that is not being replayed. Uses the wall clock, which
-- is fine: the seed is an input to the simulation, recorded in the replay header,
-- never read by the simulation itself.
function Rng.new_seed()
    return math.floor(os.time() % 2147483647)
end

return Rng
