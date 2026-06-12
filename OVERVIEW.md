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

The original prerenders every sprite rotation (a 31-frame arc per object, drawn
mirrored for the back half). **This reimplementation does not.** We use only the
axis-aligned variant of each sprite and rotate it at runtime with Love2D's
`love.graphics.draw` rotation argument. This is the single most important
architectural difference from the original and it shapes how sprites are picked
and drawn throughout `engine/`.

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
  sprite when killed. The tank turret aims and fires independently of the hull.
  Solid entities block tank movement and veto helicopter landings. Enemy AI, enemy
  fire, player death, ammo, and weapon shop are not yet implemented.

## Architecture

Love2D entry point is `main.lua`, which owns the three top-level modes:

- **Viewer** (default): free-roam camera over the stage, stage/kind pickers.
- **Game** (`F1`): camera locks to the player, world rotates so the player faces
  up, combat runs.
- **Sandbox** (`F3`): game mode plus a live vehicle-parameter editor.

Engine modules (`engine/`), all built on the tiny `class.lua` helper:

| Module | Responsibility |
|--------|----------------|
| `world.lua` | Loads a stage JSON, instantiates entities, owns the entity list, ground color, y-sorting, the heliport spawn point (`player_start`) and the solid-entity collision query (`blocked`). |
| `entity.lua` | One world object: HP, state machine (idle/animating/exploding/dead), damage smoke, hit effects, destruction crater. Loads shared type data from `data/entity_types.json`. |
| `player.lua` | Player vehicle: movement and collision, altitude/landing state (chopper only), independent tank turret, fuel, sprite frame selection per speed/strafe, weapon selection state. |
| `combat.lua` | Weapons, projectiles, firing geometry (spread/streams/swing/side offset), hit detection, AoE. Loads `data/weapons.json`. |
| `camera.lua` | Zoom, pan, world-rotation transform, viewport culling, game-mode vertical focus offset (`view_oy`, `screen_center`). |
| `renderer.lua` | Draws world entities (decals then objects, y-sorted, culled), segments, grid, pickers, viewer HUD bar. |
| `hud.lua` | Sprite-based gauges and radar from `data/hud.json`. |
| `animation.lua` | Shared immutable `AnimClip` definitions plus per-instance `AnimState` playback. Loads `data/animations.json`. |
| `debug.lua` | Debug overlay (`F2`). |

## Game controls

`F1` enters game mode and spawns the vehicle on the base heliport. WASD or arrows
drive; the chopper takes off / lands with `Space` (it bounces back up if it tries
to land on a solid obstacle). Holding `Shift` while turning strafes the chopper or
rotates the tank turret. `Ctrl` fires, `Q` cycles weapon, `E` cycles weapon level.

## Coordinate and angle conventions

- World units are original game pixels. World is `world_size` square (4096).
- Player `angle` is **degrees, 0 = north (up), clockwise positive**.
- To convert a game angle to a forward vector, use `rad = (angle - 90) * pi/180`,
  then `(cos rad, sin rad)` in Y-down screen space. `combat.lua` and `player.lua`
  both follow this; match it for any new motion or aiming code.
- The camera rotates the world by `-angle` (radians) in game mode so the player
  sprite is always drawn upright at screen center.

## Data files

| File | Contents |
|------|----------|
| `assets/stageMP.json` + `assets/stageMP/*.png` | Decoded stages and sprites (generated, not committed). |
| `data/weapons.json` | Weapon and projectile definitions, including per-level upgrades. |
| `data/entity_types.json` | Per-kind combat data (hit radius, explosion, weapon, ranges, `solid`, `collision_radius`, unit `sprite`/`dead_sprite`). |
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
