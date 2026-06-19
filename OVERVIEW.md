# OpenSeek Overview

Open-source reimplementation of *Seek & Destroy* (SAFARI Software, DOS ~1993-1995)
in Lua / Love2D 11.x.

## What the original is

A top-down vehicle combat game. The player drives a helicopter or a tank across a
4096x4096 px world, destroying enemy units and structures, collecting ammo and
medals, and buying/upgrading weapons between phases. The campaign is 5 missions x
4 phases = 20 stages.

## What this project is

A from-scratch engine that reuses the original game's **art and level data** but
not its code. Asset formats were reverse engineered (see `research/`) and exported
to neutral formats:

- Sprites: decoded from the original jump-coded Mode X blitter streams to PNG.
- Levels: decoded from the stage loader format to JSON (`assets/stageMP.json`).

The original prerenders every sprite rotation (a rotation arc per object, frame 0
the axis-aligned pose and the back half drawn mirrored). **This reimplementation
does not.** We export only the axis-aligned frame 0 (the class `frame_base`) and
rotate it at runtime with Love2D's `love.graphics.draw` rotation argument. This is
the single most important architectural difference from the original and it shapes
how sprites are picked and drawn throughout `engine/`. Earlier code treated frame
15 as axis-aligned because the BIN reader dropped frame 0; see `SPRITES.md` for the
corrected n+1 frame model. All sprite sets (stage, player, effects, projectiles,
HUD) have been re-exported with the fixed decoder.

## Current status

- **Level viewer:** complete. All 20 stages render with correct sprites, ground
  color, road/path segments, and entity placement.
- **Player vehicles:** chopper and tank with movement, takeoff/landing, fuel,
  strafing, and per-vehicle JSON tuning (`data/vehicles/*.json`). A sandbox mode
  (`F3`) live-edits and saves vehicle parameters.
- **HUD:** sprite-based gauges and a radar.
- **Combat:** in progress. Player weapons fire range-limited projectiles that hit
  entities; entities take damage, show hit/damage smoke, explode, and large static
  buildings leave a crater. Enemy soldiers are destructible and switch to a corpse
  sprite when killed, drawing their own stage's ENEMY.BIN art (alive frame 0,
  dead frame 32) so each mission's units match its theme rather than reusing
  stage00. The player tank turret aims and fires independently of the
  hull (axis-aligned frame 0, runtime-rotated like everything else). A damaged
  player vehicle trails smoke in world space (puffs spawn out of phase and sit
  in front of or behind the hull). Enemies (flak turrets, enemy tanks, soldiers)
  rotate to track the player and fire when locked and in range: flak fires paired
  accelerating animated tracers, tanks fire shells, soldiers fire rifles. A tank
  is stored in the stage as two co-located entities, a hull (kind `tank`) and a
  turret on top (a `*tanktop` sprite filed as a `flak_turret`); `world.lua` folds
  the turret onto the hull at load into one entity. Tanks carrying a route patrol
  its waypoint loop (the hull faces its travel heading while the turret tracks). The fixed hull carries a
  separate turret that spins to aim; the turret has its own HP and must be
  destroyed (it absorbs all hits and explodes first) before the hull can be
  damaged. Solid entities block tank movement and veto helicopter landings;
  player armor takes damage from enemy fire. Enemy turrets vary their weapon by
  sprite (`data/enemy_overrides.json`): gun1 fires slow homing missiles, sguntop
  spits fireballs; sgun fireballs flak-burst on impact while tracers fade out.
  GUN1's fire rate is set per stage in `data/enemy_fire_rates.json` (later phases
  fire faster). Enemy helicopters (`engine/enemy_heli.lua`) spawn off-screen at the
  stage's `badheli` marker points (one airborne per marker), fly in toward the
  player and circle it, firing one random weapon (chaingun / FFR / homing
  air_to_air / tracers) when lined up; they have a spinning rotor, smoke when hurt
  and fall-and-explode when downed, like the player, and show on the radar as
  pinkish blips. Both the player chopper and the enemy helis cast a runtime ground
  shadow (`engine/shadow.lua`): the body sprite masked to a flat translucent black
  silhouette, cast from a top-left sun toward the world bottom-right (so it swings
  with the world rotation) and scaled in offset/opacity by altitude, so a landed
  chopper casts none; shadows are disabled on the night (volcanic mission 3) stages.
  Radar
  stations are two-part like tanks (a `radar.bin` base with a `radarsp` dish that
  spins continuously and must be destroyed first). The chopper arsenal includes a
  napalm that sweeps tongues of fire outward from the chopper (1 ahead / a
  -45/0/45 fan / an 8-way ring) and an alternating-pod mega missile (smoke trail); weapons carry their
  canonical shortname (GUN/FAR/NAP/MRK/...) and WEAPONS.BIN icon. Player ammo is
  tracked per weapon (chaingun infinite, others limited); destroyed large
  buildings almost always drop a power-up (PICKUPS.BIN) that refills ammo, fuel,
  armor, or awards a medal (bunkers always drop a medal), collected by flying over
  (easy) or landing on them (hard); low armor/fuel gauges blink. `F5` toggles
  unlimited ammo/fuel/armor for testing. Game-over is optional (toggle `O` in the
  overview): when enabled, running out of fuel or armor downs the player, a
  chopper falling and exploding on the ground, a tank burning then losing its
  turret; the final explosion damages nearby entities like a bomb. `R` restarts
  the current level, `P` pauses.
- **Impact effects:** a hit on an entity puffs smoke at the impact (`Entity:on_hit`,
  default `smoke2`); FFR rockets alternate `smoke`/`smoke2` via the weapon's
  `hit_effect` list. A hit on the player vehicle bursts a random
  `fire`/`missile_smoke`/`smoke2` attached to the player (`Player:add_hit_fx`) so it
  draws on top of the vehicle; the damage-smoke trail drifts along the heading at a
  fraction of the current speed.
- **Shrapnel & dust:** explosions from large buildings and the bomb fling tumbling
  iron/metal shrapnel through one world-level system (`World:spawn_debris`), drawn
  as an overlay above the explosion effects. Each piece decelerates, and where it
  lands it kicks up a `dust0/1/2` puff on the lowest ground layer
  (`World:add_ground_dust`), beneath decals and trees.
- **Bomb:** the `bomb_drop` weapon eases forward (fast then slow) while falling
  away (the sprite shrinks slow then fast) over `fall_time`, covering
  `fly_distance`, then detonates with a large explosion, the shared shrapnel/dust,
  and full-damage AoE; it does not collide in flight
  (`Projectile:_update_bomb`, `CombatSystem:_bomb_detonate`).
- **Base refuel:** parking the vehicle on the spawn heliport / friendly base tops
  the fuel back up (`Player:_update_base_refuel`, `home_x`/`home_y` set on spawn);
  `Player.refuel_mode` selects a continuous rate or instant top-up.
- **Objectives:** each stage JSON carries a decoded `objectives` block (destroy
  targets via the class `is_target` flag; rescue via the phase flag, with
  `powhere.bin` landing zones and `pow.bin` people). The renderer reads it to
  highlight live destroy-targets (reticles), ring loose POW civilians, and mark the
  objective entities as white dots on the HUD radar. A top-center objective banner
  with a live count is shown in the stage viewer; the in-game HUD keeps the world
  reticles/rings and radar dots but no objective text.
- **Win conditions:** a per-stage mission (`data/missions.json`) optionally defines
  destroy, rescue (POW), and sabotage objectives with win/lose simulation. Progress
  is tracked live; once all objectives are met the player must fly the surviving
  people home and land on the friendly base pad to complete the phase. Stages with no
  explicit `missions.json` entry fall back to their decoded `objectives` block, so
  rescue and destroy phases still run in single player and co-op. A weapon shop is not
  yet implemented.
- **POW rescue (`rescue.lua`):** on POWHERE stages, each `powhere.bin` building holds
  POWs and cannot be destroyed (its `powhut.bin` huts are shielded) until emptied.
  Landing the vehicle on the building's `lh.bin` pad for 1.0s walks the POWs out to the
  vehicle one at a time; flying off sends them back inside. POWs can be shot in the open
  (enemy fire always; friendly fire only with `Config.friendly_fire_pows`), which drops
  them from the count. Clearing a building removes its marker and pad and unshields its
  huts. Per-building POW counts come from a stage's `rescue_pow_counts` in
  `missions.json`, defaulting to a random 1-3. Rescue stages that instead place loose
  `pow.bin` civilians keep the simpler fly-over/land-near collection.

## Architecture

Love2D entry point is `main.lua`, which owns the three top-level modes:

- **Viewer** (default): free-roam camera over the stage, stage/kind pickers.
- **Game** (`F1`): camera locks to the player, world rotates so the player faces
  up, combat runs.
- **Sandbox** (`F3`): game mode plus a live vehicle-parameter editor.

Engine modules (`engine/`), all built on the tiny `class.lua` helper:

| Module | Responsibility |
|--------|----------------|
| `world.lua` | Loads a stage JSON, instantiates entities (including per-stage unit alive/dead images), owns the entity list, ground color, the per-mission night flag (`shadows_enabled`, off on the volcanic mission 3), y-sorting, the friendly-base spawn point (`player_start`, detected from `basecirc.bin`/`h.bin`), the solid-entity collision query (`blocked`), the objective entity lists (`targets`, `rescue_zones`, `rescue_people`, `land_zones` for `lh.bin` rescue pads, `objectives`), the enemy-helicopter spawn markers (`heli_spawns`, collected from placed `enemy_helicopter` entities which are never drawn), and the shared explosion shrapnel + ground-dust systems (`spawn_debris`, `add_ground_dust`). |
| `entity.lua` | One world object: HP, state machine (idle/animating/exploding/dead), damage smoke, hit effects, destruction crater. Loads shared type data from `data/entity_types.json`. |
| `player.lua` | Player vehicle: movement and collision, altitude/landing state (chopper only), independent tank turret, fuel, sprite frame selection per speed/strafe, weapon selection state. The rotor sheets (`bladep`/`bladeb`) are 8-frame spin cycles grouped by pitch/bank position; the active group tracks the hull tilt and only its 8 frames spin, so the blades rotate smoothly. The chopper casts a ground shadow (`draw_shadow`, plus `draw_remote_shadow` for the co-op teammate seen in the other camera) that slides out and fades in with altitude. |
| `enemy_heli.lua` | Airborne enemy helicopters: spawns them off-screen at the stage's `badheli` markers (`World.heli_spawns`, count = simultaneous cap), flies them toward the player and circles, fires one random weapon when the nose lines up, smokes when damaged, and falls/explodes when downed. They cast ground shadows (`draw_shadows`) like the player. Its live list is exposed as `world.air_units` for `combat.lua` hit detection. |
| `combat.lua` | Weapons, projectiles, firing geometry (spread/streams/swing/side offset), hit detection, AoE. Loads `data/weapons.json`. Tracer weapons resolve their streak sprite to the loaded stage's mission variant (`trace`/`strace`/`jtrace`/`rtrace`). The `bomb_drop` weapon glides forward then falls and detonates with shrapnel + full-damage AoE. Homing missiles (player `locking` levels, enemy `homing` weapons) steer toward a target at a capped `turn_rate` so they can be dodged (`_steer_homing`). |
| `camera.lua` | Zoom, pan, world-rotation transform, viewport culling, game-mode vertical focus offset (`view_oy`, `screen_center`). |
| `renderer.lua` | Draws world layers bottom-to-top: ground dust (lowest), decals, segments, objects (y-sorted, culled), objective markers (destroy reticles, loose-civilian rings) and banner, grid, pickers, viewer HUD bar. Flying shrapnel is a separate overlay (`draw_debris`) drawn after the explosion effects so the chunks stay on top of the blast. |
| `hud.lua` | Sprite-based gauges, weapon icon, acceleration box, and radar from `data/hud.json`. The radar draws dots by priority (buildings, then enemies, then airborne helicopters in pink from `world.air_units`, then objectives on top in white) so the goal is never hidden. The acceleration box uses the original `BOX.BIN` art with a green dot driven by speed/strafe plus a small turn nudge. Per mission it prefers override art in `assets/hud/stage{m}/` when present (mission 3 ships a full custom armour/fuel/weapons/scanner/box set, 1-2 only armour), falling back per item to the shared `assets/hud/` set (`Hud:set_mission`). A global `Config.hud_scale` grows every element and its edge inset together so corner-anchored items stay in their corners. |
| `powerups.lua` | Power-up drops from destroyed large buildings: spawn, ttl/blink, fly-over vs land-on collection, and effect application. Frames from the `pickup` clip. Honors `Config.axis_aligned_pickups` (draws them screen-upright, like the original engine, instead of rotating with the world). |
| `mission.lua` | Per-stage win conditions: destroy / rescue / sabotage objectives, progress tracking, and the return-to-base landing requirement. Data-driven from `data/missions.json`, falling back to the stage's own decoded `objectives` block when a stage has no explicit entry (so single player and co-op share the same goals). POWHERE rescue objectives delegate their progress to `rescue.lua`; loose-civilian rescue stages keep the simple fly-over collection. `rescue_pow_counts` (per stage) sets exact POWs per building. |
| `rescue.lua` | POW rescue from POWHERE buildings: pairs each `powhere.bin` marker with the nearest `lh.bin` land pad and with the destructible building directly under it (any co-located `structure`, e.g. `bunker2.bin`/`powhut.bin`, paired like a tank hull under its turret) which it shields from damage while the building still holds POWs. Landing on the pad for 1.0s sends POWs (`newdude0`/`pow0`/`pow1` walk clips, rotated to face their path) out one by one to the vehicle (rescued on contact, added to `Player.pows`); leaving sends them back inside. A POW can be shot in the open (enemy fire always, friendly fire only with `Config.friendly_fire_pows`), which drops it from the required count. Emptying a building removes its marker and land pad and unshields the building. The POWHERE marker and its land pad are the only in-world cue (no reticle ring). Land pads honor `Config.axis_aligned_pickups` like power-ups. POW counts come from `Mission.rescue_counts` (per-building) or a random 1-3. |
| `animation.lua` | Shared immutable `AnimClip` definitions plus per-instance `AnimState` playback. Loads `data/animations.json`. |
| `shadow.lua` | Helicopter ground shadows: one light model (sun fixed at the top-left of the unrotated world, so shadows fall to the bottom-right and swing with the world rotation) and a `draw` helper that masks the body sprite to a flat black silhouette. Used by `player.lua` (screen space, offset scaled by draw size) and `enemy_heli.lua` (world space); both scale offset and opacity by altitude and skip night missions (`World:shadows_enabled`). |
| `config.lua` | Optional compatibility / gameplay tuning shared across systems, set from the overview SETUP panel before launching a level. `axis_aligned_pickups` keeps pickups (and POW rescue land pads) screen-upright; `friendly_fire_pows` lets the player's own fire kill walking POWs; `hud_scale` scales the on-screen HUD (each element and its inset from the screen edge) toward the chunkier DOS size; `speed_scale` is a global multiplier on gameplay motion (player/heli/enemy movement and turning, projectile and homing speeds) applied at each motion-integration site, deliberately leaving animation playback unscaled so the game looks the same at a different pace. |
| `screen.lua` | Fullscreen image overlay with fade-in / hold / fade-out (one at a time): the `TITLE` card at launch, the per-mission briefing picture (`STAGE0X_MPIC`) before a level starts, and the crash end screen (`DEATHPIC` chopper / `TANKEND` tank). Images live in `assets/fullscreen/`. |
| `debug.lua` | Debug overlay (`F2`): click to select an entity (overlap pick-list), inspect it, and edit every `type_data` field (numbers step, bools toggle, string fields cycle known values). `[S]` saves all fields per kind to `data/entity_types.json`. While the pick-list / picker / field editor is open the overview camera is held still (`captures_arrows`) and the focused overlapping entity glows in the world (`highlight_entity`). |

## Game controls

`F1` enters game mode and spawns the vehicle on the friendly base pad; the chopper
lifts off automatically. WASD or arrows drive; the chopper lands / takes off again
with `Space` (it bounces back up if it tries to land on a solid obstacle). Holding `Shift` while turning strafes the chopper or
rotates the tank turret. `Ctrl` fires, `Q` cycles weapon, `E` cycles weapon level.
`F5` toggles unlimited ammo/fuel/armor (god mode); `F6` toggles power-up pickup
between easy (fly-over) and hard (land-on); `R` restarts the current level; `P`
pauses. The overview screen presents a SETUP panel (top-left, in titled boxes):
`V` switches vehicle, `O` toggles optional game-over (death), `C` toggles
axis-aligned vs world-rotated pickups, and `[` / `]` step the `speed_scale`
gameplay-motion multiplier (all of these feed `engine/config.lua` and the live
game). `F8` opens the animation gallery: a test overlay that plays every clip in
`data/animations.json` at once in a labelled grid (`Esc`/`F8` to close).

A fade-in `TITLE` card shows at launch. Pressing `F1` first shows the loaded
stage's briefing picture (`STAGE0X_MPIC`, selected by the mission digit of the
stage name) and then drops into the live game with a short eased zoom-in
(`Camera:start_zoom_intro`); the chopper lifts off the pad once the zoom-in ends.
With game-over enabled, a fatal crash plays the
wreck animation, waits ~3 seconds, then fades up the end picture (`DEATHPIC` for
the chopper, `TANKEND` for the tank); any key restarts the level. `Esc` skips the
current picture and returns to the overview, and from game mode it returns to the
overview too; it never quits the game.

## Coordinate and angle conventions

- World units are original game pixels. World is `world_size` square (usually
  4096).
- The map is a seamless torus: leaving one edge re-enters from the opposite one,
  like the original. The player position wraps (`Player:_move`), world-space draw
  passes are tiled per overlapping map copy (`Camera:tiles`, used by the renderer,
  combat, powerups, and the smoke trail), and every distance check uses the
  shortest wrapped delta (`World:delta`) so collision, AI, hits, pickups, the
  radar, and `Camera:project` work across the edges. Projectiles keep flying in
  unbounded coordinates and are culled by range/ttl; the tiled draw places them
  next to a player at the seam.
- A few stages (mission 0 phases 0-2) inset their content ~48px from the edges:
  the field spans e.g. `[48, 4047]` inside a nominal 4096 world. Its width is the
  natural wrap period (the right edge continues into the left: `4047 + 1 == 48`
  mod 4000), so `World:_fit_wrap_period` shrinks `world_size` to that extent at
  load. Every system wraps on the one `world_size`, so the seam lines up exactly
  with no bare band; full-bleed stages already reach the edges and keep 4096.
- Player `angle` is **degrees, 0 = north (up), clockwise positive**.
- To convert a game angle to a forward vector, use `rad = (angle - 90) * pi/180`,
  then `(cos rad, sin rad)` in Y-down screen space. `combat.lua` and `player.lua`
  both follow this; match it for any new motion or aiming code.
- The camera rotates the world by `-angle` (radians) in game mode so the player
  sprite is always drawn upright at screen center.

## Mission objectives

Two layers cooperate, both keyed off the JSON contract:

- **Decoded objective block (visualization).** Each `assets/stageMP.json` has an
  `objectives` block (`destroy`, `rescue`, `special_end`, `target_classes`,
  `n_target_entities`) derived from the phase flag byte and the placed entities
  (`decode_level.py`). `world.lua` collects the matching entities
  (`targets`, `rescue_zones`, `rescue_people`) at load and `renderer.lua` draws the
  on-map markers and objective banner. No hand authoring required; covers all 20
  stages (phases 11/13/32 carry no resolvable goal and show nothing).
- **Hand-authored missions (win/lose).** `data/missions.json` is a map of stage
  name to a richer mission def driving the live win/lose simulation
  (return-to-base, carried people, sabotage). A stage without an entry has no win
  condition (free play) but is still visualized from the objective block above.

```jsonc
{
  "stage01": {
    "briefing": "Rescue the POWs, level the radar, return to base.",
    "home_radius": 48,                 // landing tolerance at the base pad (px)
    "home_base_asset": "lh.bin",       // optional: base pad sprite, when it is
                                       // not the auto-detected basecirc.bin / h.bin
    "objectives": [
      // destroy: count kills of entities matched by asset filename and/or kind.
      // count is a number or "all" (default). min_size gates by sprite size (px).
      { "type": "destroy", "target": "radar.bin", "count": "all" },
      { "type": "destroy", "kind": "structure", "min_size": 28, "count": 5,
        "label": "Flatten the depots" },

      // rescue: pick up people by sitting (chopper landed / tank stopped) within
      // radius of each matched pickup entity. count defaults to the match count.
      { "type": "rescue", "target": "pow.bin", "radius": 40, "count": 4 },

      // sabotage: dwell deploy_radius near each matched building for deploy_time
      // to plant a charge; once all are planted the buildings blow, then dwell
      // again at each to recover the unit (evacuate). Objective done when all
      // units are evacuated.
      { "type": "sabotage", "target": "factory.bin",
        "deploy_radius": 40, "deploy_time": 2.0 }
    ]
  }
}
```

Matching is by `target` (asset `.bin` filename), `kind` (`kind_name`), and
`min_size`, any of which may be omitted. Use the F2 debug inspector (`asset` /
`sprite` rows, selection highlighting) to find the right filename for a target
or the friendly base pad. The base pad is auto-detected from `basecirc.bin` (or
the `h.bin` heliport stamped on it in missions 0/3); once every objective is met
the player must land on it to win.

## Data files

| File | Contents |
|------|----------|
| `assets/stageMP.json` + `assets/stageMP/*.png` | Decoded stages and sprites. Each stage JSON includes an `objectives` block and a per-class `is_target` flag; each render PNG is the axis-aligned `frame_base` (frame 0). Unit classes also export a sibling dead-pose frame (`{stem}_f{frame_base + dead_frame_offset}.png`) the engine derives by name. |
| `data/weapons.json` | Weapon and projectile definitions: per-level upgrades, `short`/`icon` (WEAPONS.BIN), `ammo_max`/`ammo_pickup`, plus `alternate_side`/`trail` (mega missile) and `flame` cone params (napalm). |
| `data/entity_types.json` | Per-kind combat data (hit radius, explosion, weapon, ranges, `solid`, `collision_radius`, unit `sprite`/`dead_sprite` fallback clips, `dead_frame_offset` for the per-stage corpse frame, two-part tank `turret_hp`/`turret_explosion`). |
| `data/enemy_overrides.json` | Per-sprite enemy weapon overrides (asset filename -> weapon), for turrets that share the `flak_turret` kind but fire different weapons. |
| `data/enemy_fire_rates.json` | Per-stage enemy fire-rate overrides (stage name -> asset filename -> shots/sec), e.g. GUN1 firing faster in later mission-0 phases. |
| `data/enemy_muzzle.json` | Per-sprite forward muzzle offset (asset filename -> px) so enemy shots leave the barrel instead of the hull center. |
| `data/building_drops.json` | Forced power-up drops on a building's destruction (asset filename -> pickup kind, e.g. `bunker.bin` -> `medal`). |
| `data/missions.json` | Optional per-stage win/lose missions (objective list + return-to-base). See "Mission objectives". Empty by default; the auto-decoded `objectives` block in each stage JSON drives the on-map markers and banner without it. |
| `data/vehicles/*.json` | Player vehicle tuning. |
| `data/animations.json` | Named animation clips (explosions, smoke, rotors, projectile sprites). |
| `data/hud.json` | HUD layout and gauge sprites. |

## Building assets

Requires the original game files. Point the Python tools at the extracted
`STAGE0X/` and `data/` directories:

```bash
pip install pillow numpy
python3 tools/export_love2d.py all   # writes assets/stageMP{.json,/*.png}
love .                               # run
love . stage12                       # open a specific stage
```

See `README.md` for controls and `research/` for the reverse engineering record.
