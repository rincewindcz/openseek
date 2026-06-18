-- Optional compatibility / gameplay tuning shared across systems. A future setup
-- menu will edit these; the F2 debug overlay toggles them live for testing.
local Config = {
  -- Render pickups screen-aligned, the way the original engine did (it could not
  -- rotate sprites), instead of rotating them with the world.
  axis_aligned_pickups = false,

  -- Global multiplier on gameplay motion: movement, turning, projectile and
  -- weapon speeds. Animation playback is deliberately left unscaled so the game
  -- looks identical while playing at a different pace. 1.0 = current/modern
  -- speed; lower values slow the game toward the DOS original.
  speed_scale = 1.0,
}

return Config
