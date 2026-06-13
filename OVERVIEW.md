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
  sprite (`data/enemy_overrides.json`): gun1 fires rockets, sguntop spits
  fireballs; sgun fireballs flak-burst on impact while tracers fade out. Radar
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
- **Objectives:** each stage JSON carries a decoded `objectives` block (destroy
  targets via the class `is_target` flag; rescue via the phase flag, with
  `powhere.bin` landing zones and `pow.bin` people). The renderer reads it to
  highlight live destroy-targets (reticles), ring POW landing zones, and mark the
  objective entities as white dots on the HUD radar. A top-center objective banner
  with a live count is shown in the stage viewer; the in-game HUD keeps the world
  reticles/rings and radar dots but no objective text.
- **Win conditions:** a per-stage mission (`data/missions.json`) optionally defines
  destroy, rescue (POW), and sabotage objectives with win/lose simulation. Progress
  is tracked live; once all objectives are met the player must fly the surviving
  people home and land on the friendly base pad to complete the phase. Stages with no mission entry are free play (the objective
  block above is still visualized). A weapon shop is not yet implemented.

## Architecture

Love2D entry point is `main.lua`, which owns the three top-level modes:

- **Viewer** (default): free-roam camera over the stage, stage/kind pickers.
- **Game** (`F1`): camera locks to the player, world rotates so the player faces
  up, combat runs.
- **Sandbox** (`F3`): game mode plus a live vehicle-parameter editor.

Engine modules (`engine/`), all built on the tiny `class.lua` helper:

| Module | Responsibility |
|--------|----------------|
| `world.lua` | Loads a stage JSON, instantiates entities (including per-stage unit alive/dead images), owns the entity list, ground color, y-sorting, the friendly-base spawn point (`player_start`, detected from `basecirc.bin`/`h.bin`), the solid-entity collision query (`blocked`), and the objective entity lists (`targets`, `rescue_zones`, `rescue_people`, `objectives`). |
| `entity.lua` | One world object: HP, state machine (idle/animating/exploding/dead), damage smoke, hit effects, destruction crater. Loads shared type data from `data/entity_types.json`. |
| `player.lua` | Player vehicle: movement and collision, altitude/landing state (chopper only), independent tank turret, fuel, sprite frame selection per speed/strafe, weapon selection state. |
| `combat.lua` | Weapons, projectiles, firing geometry (spread/streams/swing/side offset), hit detection, AoE. Loads `data/weapons.json`. |
| `camera.lua` | Zoom, pan, world-rotation transform, viewport culling, game-mode vertical focus offset (`view_oy`, `screen_center`). |
| `renderer.lua` | Draws world entities (decals then objects, y-sorted, culled), segments, grid, objective markers (destroy reticles, POW landing rings) and banner, pickers, viewer HUD bar. |
| `hud.lua` | Sprite-based gauges, weapon icon, and radar from `data/hud.json`; the radar marks enemies, buildings, and objective entities (white) as dots. |
| `powerups.lua` | Power-up drops from destroyed large buildings: spawn, ttl/blink, fly-over vs land-on collection, and effect application. Frames from the `pickup` clip. |
| `mission.lua` | Per-stage win conditions: destroy / rescue / sabotage objectives, progress tracking, and the return-to-base landing requirement. Data-driven from `data/missions.json`. |
| `animation.lua` | Shared immutable `AnimClip` definitions plus per-instance `AnimState` playback. Loads `data/animations.json`. |
| `debug.lua` | Debug overlay (`F2`). |

## Game controls

`F1` enters game mode and spawns the vehicle on the friendly base pad; the chopper
lifts off automatically. WASD or arrows drive; the chopper lands / takes off again
with `Space` (it bounces back up if it tries to land on a solid obstacle). Holding `Shift` while turning strafes the chopper or
rotates the tank turret. `Ctrl` fires, `Q` cycles weapon, `E` cycles weapon level.
`F5` toggles unlimited ammo/fuel/armor (god mode); `F6` toggles power-up pickup
between easy (fly-over) and hard (land-on); `R` restarts the current level; `P`
pauses. In the overview screen, `O` toggles optional game-over (death) on or off.

## Coordinate and angle conventions

- World units are original game pixels. World is `world_size` square (4096).
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
