# OpenSeek Overview

Architecture, systems and current status. Conventions for writing code live in
`OVERVIEW.md`; additions beyond the original in `EXTRA.md`; open work in
`TODO.md`; the replay contract in `DETERMINISM.md`; the reverse engineering
record in `research/`.

## 1. What this is

*Seek & Destroy* (SAFARI Software, DOS ~1993-1995) is a top-down vehicle combat
game: the player drives a helicopter or a tank across a 4096x4096 px world,
destroying enemy units and structures, collecting ammo and medals, and buying or
upgrading weapons between phases. The campaign is 5 missions x 4 phases = 20
stages.

openSEEK is a from-scratch Lua / Love2D 11.x engine that reuses the original's
**art and level data** but none of its code. The formats were reverse engineered
(`research/`) and exported to neutral ones: sprites from the jump-coded Mode X
blitter streams to PNG, levels from the stage loader format to JSON
(`assets/stageMP.json`).

**The one architectural difference that shapes everything else:** the original
prerenders every sprite rotation (a rotation arc per object, frame 0 the
axis-aligned pose, the back half drawn mirrored). This engine exports only the
axis-aligned frame 0 (the class `frame_base`) and rotates it at runtime with
`love.graphics.draw`. See `OVERVIEW.md` rule 1 and `research/SPRITES.md` for the
n+1 frame model.

## 2. Status

| Metric | Value |
|--------|-------|
| Engine | 16013 lines Lua, 64 files in `engine/` + `main.lua` + `conf.lua` |
| Scenes | 18 registered, plus the shared `gameplay_base` |
| Asset pipeline | 9783 lines Python, 36 tools in `tools/` |
| Stages | 20 / 20 decoded, rendered and playable |
| Exported art | 2074 PNG, 8 bitmap fonts, 30 fullscreen pictures, 59 WAV |
| Data tables | `weapons` (16), `entity_types` (10 kinds), `animations` (69 clips), `missions` (16 stages), `mission_text` (20 stages), `audio` (39 events) |
| Lint | `luacheck engine main.lua conf.lua`: 0 warnings / 0 errors |

The game is complete and playable end to end: title, menu, briefing, equip,
shop, 20 stages with objectives and win/lose, lives and score progression, the
end-of-phase stats screen, high scores, split-screen co-op, and deterministic
replays. Runtime target is Love2D 11.x; the code also runs under love.js
(`goto`/`continue` avoided throughout).

Status key: **Done** = complete for its scope. **Partial** = usable with named
gaps. Everything under Partial or Missing is tracked in `TODO.md`.

| Area | Status | Notes |
|------|--------|-------|
| Shell and flow | Done | Scene stack, title, fades, main menu, briefing, mission picker, options, credits, high scores, campaign progression, pointer / touch input |
| Stage load and render | Done | All 20 stages: sprites, ground colour, road/path segments, entity placement, toroidal wrap, two-pass ground/object render, y-sorting, culling |
| Player vehicles | Done | Chopper (3 skins) and tank, movement, takeoff/landing, fuel, armor, collision, base refuel, independent tank turret, destruction sequences, lives and respawn, JSON tuning |
| Combat | Done | Data-driven weapons and projectiles, homing with capped turn rate, per-weapon ammo, power-ups, damage model with AoE and craters |
| Enemy AI | Partial | Turrets, tanks, soldiers, patrol routes, hangar tanks, two-part units, enemy helicopters. No line of sight: enemies fire through buildings |
| Missions and objectives | Done | Destroy / POW rescue / sabotage, return to base, end-of-phase stats. All 20 stages have a win condition |
| Equip, shop, HUD | Partial | Full equip and shop screens with a campaign inventory; 5 catalogued weapons have no definition yet and render darkened |
| Effects | Done | Night lighting, flash FX, weather, shadows, shrapnel, ground dust, smoke and hit effects |
| Determinism and replay | Done | Fixed 60 Hz tick, seeded RNG, input frames, recorded runs, `F4` browser, self-test |
| Netplay | Missing | Prerequisites all landed; transport and lockstep remain (`DETERMINISM.md` section 5) |
| Audio | Done | Directional mixer: 59 SFX on named events, per-listener panning and distance, split-screen aware, engine loops, radio callouts, five volume buses. Music is a wired bus with no bundled tracks |
| Save / load | Missing | Campaign progress lives only in memory; the LOAD entry and the briefing SAVE / LOAD buttons are inert |
| Level editor | Partial | The EDITOR entry opens the overview, which edits entity *types*, not placement |

## 3. Architecture

`main.lua` builds the shared systems into an `app` context table, registers the
scenes with the stack-based scene manager (`core/scene_manager.lua`), and
delegates every `love.*` callback to the fullscreen fade overlay plus the top
scene.

`love.update` runs a **fixed simulation step**: a scene marked `fixed_step` (the
gameplay scenes, via `GameplayBase`) is advanced in whole 1/60 s ticks with
catch-up clamped to 5 ticks so a stall cannot jump the vehicle; every other scene
keeps the real frame delta. Gameplay therefore plays out identically at any
frame rate, which is the first requirement for recording and replaying a run.
The rules that keep it that way are in `DETERMINISM.md` and enforced by
`tools/check_determinism.sh`.

### Scenes

Each top-level mode is a scene in `engine/scenes/`, subclassing
`core/scene.lua`. Scenes address each other by name, never by require.

| Scene | Role |
|-------|------|
| `title` -> `main_menu` | Boot flow. The menu is also pushed over a running game (`Esc`), where RESUME pops back |
| `credits` / `hiscores` | Info screens over the shared `ui/info_screen.lua` shell. The top-10 table persists and opens a name-entry row on a qualifying score |
| `advanced_settings` | The OPTIONS screen: DISPLAY, VIDEO, AUDIO, CONTROLS, GAMEPLAY, EXTRAS pages editing `Config` live |
| `mission_briefing` / `mission_select` | Pre-mission menu (briefing text, phase selectors, SHOP / PLAY) and the debug mission/phase picker |
| `equip` | Vehicle select and weapon-bay equip between PLAY and the phase; skipped when `assets/equip/` is absent |
| `shop` | The `POWUP` / `POWUPT` weapon shop, buying levels with medals |
| `overview` (EDITOR) | Free-roam camera over the stage, stage and kind pickers, the SETUP/START/EDITOR/VIEW panel, mode-launch keys. The entity editor is always on here |
| `gameplay` (`F1`) | Camera locks to the player, the world rotates so the player faces up, combat runs |
| `sandbox` (`F3`) | Extends gameplay with a live vehicle-parameter editor |
| `coop_setup` / `coop_gameplay` (`F7`) | 2P setup overlay and split-screen co-op |
| `replays` (`F4`) | Replay browser: play back, verify, toggle recording, delete |
| `anim_gallery` / `font_gallery` / `sound_gallery` (`F8`/`F9`/`F10`) | Dev test overlays for animation clips, bitmap fonts and decoded SFX |

`gameplay_base.lua` is the shared base for the three gameplay scenes: firing,
weapon cycling, landing, tick accounting and mission-won sequencing.

### Modules

All built on the tiny `core/class.lua` helper.

| Module | Responsibility |
|--------|----------------|
| `core/class.lua` | Minimal class/inheritance helper. |
| `core/scene.lua` | Scene base class: lifecycle hooks, update/draw, input handlers, `ui_pointer` and `fixed_step` flags. |
| `core/scene_manager.lua` | Stack-based manager: name registry, `switch`/`push`/`pop`/`replace`, dispatch to the top scene only. |
| `core/camera.lua` | Zoom, pan, world-rotation transform, viewport culling, tiled wrap passes (`tiles`), the fixed gameplay zoom reference (`game_zoom`). |
| `core/config.lua` | Shared tuning and compatibility flags, with `PERSISTED` scalars saved to `data/settings.json`. See `EXTRA.md`. |
| `core/display.lua` | Window mode through `love.window`: size presets, fullscreen, vsync, applied from the persisted `Config` keys. |
| `core/input.lua` | Central rebindable key map for the single-player gameplay actions, persisted to `data/keybinds.json`. Co-op keeps its own fixed per-player sets. |
| `core/input_frame.lua` | One tick's input for one player: a held-action bitmask plus the edge actions that fired. The only way input reaches the simulation; the bit order is part of the replay format. |
| `core/input_source.lua` | Where a tick's frames come from: `Local` samples the keyboard once per tick, `Replay` returns recorded frames, `Remote` is the netplay stub. |
| `core/rng.lua` | Seeded simulation randomness (`world.rng`, one generator per phase from the run seed) plus the draw counter the replay checksum folds in. |
| `core/animation.lua` | Immutable `AnimClip` definitions from `data/animations.json` plus per-instance `AnimState` playback. |
| `core/audio.lua` | The mixer: the `data/sounds.json` clip catalog the F10 gallery browses, plus named events from `data/audio.json` played through a per-clip voice pool, named volume buses, ducking, stereo placement / distance filtering, and the optional music track. |
| `core/font.lua` | Original bitmap fonts from `assets/fonts/`: one atlas plus per-glyph quads, `print`/`print_word` at a scale and tint. Mask fonts export as white-on-alpha intensity and are tinted at draw time; truecolor fonts keep their baked RGB and honor alpha. |
| `core/screen.lua` | Fullscreen image overlay with fade in / hold / fade out, one at a time: the `TITLE` card, the per-mission briefing picture, the crash end screen. |
| `core/mathx.lua` | The `atan2` LuaJIT/5.3 shim and `heading_deg` in the project angle convention. |
| `game/world.lua` | Loads a stage JSON and owns everything in it: the entity list, ground colour, per-mission night flag, y-sorting, the friendly-base spawn point, the solid-entity collision query (`blocked`), the objective entity lists, enemy-heli spawn markers, the shrapnel and ground-dust systems, the simulation clock (`world.time`), `world.rng` and the frozen `world.params`. |
| `game/entity.lua` | One world object: HP, state machine (idle / animating / exploding / dead), damage smoke, hit effects, destruction crater. Type data from `data/entity_types.json`. |
| `game/player.lua` | Player vehicle: movement and collision, altitude and landing, independent tank turret, fuel, per-state sprite frame selection, rotor spin groups, weapon and ammo state, the death sequence, chopper skins. |
| `game/enemy_heli.lua` | Airborne enemy helicopters: off-screen spawn at the stage's `badheli` markers, approach and orbit, random weapon, damage smoke, fall and explode. Exposed to combat as `world.air_units`. |
| `game/combat.lua` | Weapons, projectiles, firing geometry (spread, streams, swing, side offsets, alternating pods), hit detection, AoE, transient effects, and the enemy ground AI. Data-driven from `data/weapons.json`. |
| `game/mission.lua` | Per-stage win conditions: destroy / rescue / sabotage objectives, progress tracking, the return-to-base landing. `Mission.for_stage(world, players, stage_name)` serves single player and co-op alike, falling back to the stage's decoded `objectives` block. |
| `game/rescue.lua` | POW rescue from `powhere.bin` buildings: pads, shielding, walking POWs out to a landed vehicle and back, shootable POWs, per-building counts. |
| `game/saboteur.lua` | Sabotage objective: land on a pad, an agent walks into the target building, plants, returns for pickup. `individual` and `all` detonation modes, `killable` agents. |
| `game/powerups.lua` | Power-up drops from destroyed large buildings: spawn, ttl and blink, fly-over vs land-on collection, effect application. |
| `game/renderer.lua` | Draws world layers bottom to top in two passes, a ground pass (dust, decals, segments, craters) and an object pass (y-sorted, culled, objective markers), so tall props occlude a tank while flat clutter stays under it. Flying shrapnel is a separate overlay. |
| `game/lightfx.lua` | Night light map (ambient dimming, headlight cone, explosion and muzzle point lights) and the additive oversaturation layer. See `EXTRA.md`. |
| `game/sound.lua` | Directional game audio over `core/audio.lua`: per-camera listeners, loudest-listener selection, panning in the rotated view frame, distance attenuation in fixed world units, vehicle engine loops and the radio callout queue. Fed from the simulation through `World:sound` / `World:say`. See section 8. |
| `game/shadow.lua` | Helicopter ground shadows: one light model plus a helper that masks the body sprite to a flat silhouette, scaled by altitude, skipped on night missions. |
| `game/weather.lua` | World-space tiled particle field: snow on mission 1, rain on mission 2. Presentation only, on the global RNG. |
| `game/vehicles.lua` | Vehicle catalogue: free-play weapon cycles, the equip-screen bay and special lists, bay counts, the skin picker cycle, UI labels. |
| `game/loadout.lua` | Campaign weapon inventory: owned level per weapon, bay assignments (bay 1 fixed chain gun), the loaded special, `weapon_list` with bay-count ammo multipliers, `buy` from medals, and `active(app)` picking campaign vs MISSION-mode purse. |
| `game/stats.lua` | Destruction-stats bookkeeping shared by gameplay and the end screen: kind tables, `kind_category`, `destructible_totals`, `stage_phase`. |
| `game/replay.lua` | Recorded run: header, delta encoded per-tick input, periodic state checksums, the `replays/*.osr` file format, the listing, and `Replay.checksum`. |
| `ui/hud.lua` | Sprite gauges, weapon icon, acceleration box, radar with priority layering, bitmap-font counters (score, lives, POWs, ammo), the OVERKILL streak banner. Per-mission override art from `assets/hud/stage{m}/`, scaled by `Config.hud_scale`. |
| `ui/end_stats.lua` | End-of-phase DESTRUCTION STATS screen: five tallied lines with proportional `KILLICON` rows, the spinning OK badge, a running total, count-up or count-down. Co-op shows a value column per player. |
| `ui/equip_screen.lua` | The EQUIP CHOPPER / EQUIP TANK widget layer over `assets/equip/layout.json`: weapon rows in their live state, level pips, specials, OK / EXIT / TANK|CHOP. Edits the passed `Loadout` in place. |
| `ui/shop_screen.lua` | The `POWUP` / `POWUPT` shop: three level buttons per weapon category (owned ringed, affordable bright, too expensive dimmed), direct purchase from the shared medal purse. |
| `ui/menu.lua` | Main-menu widget over the `MAINP` backdrop, rendered from the `mainmen` word-art font, hover-to-focus with press/release confirm, disabled entries dimmed. |
| `ui/mission_menu.lua` | Pre-mission briefing menu: phase selectors, the SAVE / LOAD / SHOP / PLAY / EXIT button row, the objective icon column, and the original briefing paragraphs. |
| `ui/mission_select.lua` | Debug mission/phase picker: a `STAGE0X_MPIC` carousel tinted toward the selected mission's colour, phase buttons, keyboard-first navigation. |
| `ui/info_screen.lua` | Shared shell for CREDITS / HIGH SCORES: backdrop, one-shot title zoom-in, caller-supplied body, EXIT button. |
| `ui/pointer.lua` | Shared mouse/touch pointer for the non-game screens: draws the `SELPOINT` cursor and converts window pixels into the 320x240 design space so menus hit-test exactly what they render. |
| `ui/layout.lua` | The 320x240 design space and the `fit` letterbox transform used by every non-game screen. |
| `dev/debug_panel.lua` | Entity editor / debug overlay: click to select (with an overlap pick-list), inspect, and edit every `type_data` field; per-entity actions (play animation, fire weapon, kill, revive) and save to `data/entity_types.json`. Always on in the overview, `F2`-toggled in gameplay. |
| `dev/selftest.lua` | Determinism self-test (`love . --selftest`): runs a scripted phase three ways and compares the simulation tick by tick. |

## 4. Coordinate and angle conventions

- World units are original game pixels; the world is `world_size` square (usually
  4096).
- The map is a **seamless torus**. Position wraps (`Player:_move`), world-space
  draw passes are tiled per overlapping map copy (`Camera:tiles`, used by the
  renderer, combat, powerups and the smoke trail), and every distance check uses
  the shortest wrapped delta (`World:delta`), so collision, AI, hits, pickups,
  the radar and `Camera:project` all work across the edges. Projectiles fly in
  unbounded coordinates and are culled by range or ttl.
- A few stages (mission 0 phases 0-2) inset their content ~48 px from the edges,
  so the field spans e.g. `[48, 4047]` inside a nominal 4096 world. That width is
  the natural wrap period, and `World:_fit_wrap_period` shrinks `world_size` to
  it at load so the seam lines up with no bare band.
- Player `angle` is **degrees, 0 = north (up), clockwise positive**.
- To convert an angle to a forward vector: `rad = (angle - 90) * pi/180`, then
  `(cos rad, sin rad)` in Y-down screen space. For the draw rotation of a frame-0
  sprite, pass the heading directly; frame 0 already points north.
- The camera rotates the world by `-angle` in game mode, so the player sprite is
  always drawn upright at screen center.

## 5. Combat

`combat.lua` owns weapons, projectiles and transient effects. `fire()` builds
projectiles from a weapon def and a level index, applying spread, multiple
streams, swing, perpendicular side offsets and `alternate_side`; `proj_type
"flame"` routes to a damaging fire cone instead, and `bomb_drop` glides forward
while falling away before detonating with shrapnel and full-damage AoE.
`update()` advances and culls projectiles and effects, then runs hit detection,
split player-vs-entity and enemy-vs-player. Player shots reach a fixed 640 world
px unless the weapon overrides `range`; nothing about combat depends on the
window or the camera.

Projectiles carry an `owner` (`"player"` or the firing entity). Homing missiles
(player `locking` levels, enemy `homing` weapons) steer toward their target at a
capped `turn_rate` so they can be evaded. Player ammo lives on `player.lua`
(`seed_ammo` / `has_ammo` / `consume_ammo` / `add_ammo`) and
`GameplayBase:fire_for` gates on it. Route all projectile spawning through
`combat:fire` so the geometry stays in one place, and keep the player and enemy
paths symmetric where it makes sense.

### Ground combatants

Any entity whose type has a `weapon` and `detection_radius > 0` is a combatant
(`world.combatants`), driven by `CombatSystem:_update_ai`.

| Kind | Weapon | detection_radius | attack_range | turn_speed | reaction_delay | Moves |
|------|--------|-----------------|--------------|-----------|----------------|-------|
| soldier | rifle | 280 | 220 | 100 deg/s | 0.7 s | no |
| soldier_aggressive | rifle | 320 | 240 | 150 deg/s | 0.4 s | no |
| flak_turret | heavy_flak (paired tracers) | 320 | 240 | 120 deg/s | 0.6 s | no |
| tank | flak (single tracer) | 360 | 260 | 70 deg/s | 0.9 s | patrols routes (28 px/s) |

- **Detect:** engages the nearest live player while it is within
  `detection_radius`.
- **Aim:** rotates toward the player at `turn_speed`. Single-sprite units rotate
  whole; a tank keeps its hull still and tracks with the turret overlay.
- **Reaction delay:** holds fire for `reaction_delay` after the player enters
  detection, giving a window to evade. Resets when the player leaves.
- **Fire:** once the delay elapses, fires when aim is within `LOCK_DEG` (8 deg)
  and inside `attack_range`, on a cadence from the weapon or
  `data/enemy_fire_rates.json`.
- **Muzzle offset:** shots spawn `muzzle_offset` px ahead of the hull center
  along the aim (per-kind `type_data`, or a per-sprite `data/enemy_muzzle.json`
  override), so rounds leave the barrel.
- **Weapon by sprite:** turrets sharing the `flak_turret` kind fire different
  weapons per sprite through `data/enemy_overrides.json` (gun1 slow homing
  missiles, sguntop fireballs).

**Two-part objects.** A tank is stored as two co-located entities, a hull and a
`*tanktop` turret; a radar station is a base plus a spinning dish. `world.lua`
folds them at load (`TURRET_DEFS`). The turret has its own HP, absorbs all
damage and explodes first; the hull is only vulnerable once it is gone. A turret
with `spin` rotates on its own, otherwise the AI aims it.

**Tank patrol.** A tank carrying a route follows its waypoints with eased
accel/decel, keeps rolling during the reaction window, then slows to a stop just
before each shot as a telegraph and resumes.

**Hangar tanks (stage12).** A `shut.bin` hut co-located with a tank links as a
hideout (`World:_link_hangar_tanks`). The tank rides out along its `tanktrak`
axis to fire when a player is near but not facing the hut, lingers `ride_linger`
seconds after losing its shot, then ducks back. While hidden it is shielded
(skipped by all player hit, AoE and lock tests) and drawn under the hut, which
takes damage first. The hull faces its fixed ride axis; only the turret aims.

### Enemy helicopters

Spawned from the stage's `badheli` markers, capped at the marker count, with
their own flight AI in `HeliSystem`. Constants at the top of `enemy_heli.lua`:
`SPEED` 110 px/s (slower than the player, so it can be engaged), `TURN_RATE`
120 deg/s, `ORBIT_R` 270, `ATTACK_R` 360, `FIRE_CONE` 32 deg, `MAX_HP` 60 (worth
70 points), `BLAST_RADIUS` 70 / `BLAST_DAMAGE` 40 on death, `REACTION_DELAY`
0.9 s, `FRONT_LIMIT` 90 deg, `FIRE_FRONT` 115 deg.

- **Spawn:** one heli per off-screen marker, one every `SPAWN_DELAY` (2.5 s)
  while under the cap and while the player is alive. Each gets one of four
  loadouts from `WEAPON_POOL`: chaingun (3-round burst), homing_missile (single),
  air_to_air level 2 (single, homing), machine_gun (4-round burst).
- **Move:** heads straight at the player beyond `ORBIT_R * 1.25`, otherwise
  orbits with its nose sweeping between tangential and player-facing so it
  periodically lines up a shot. The orbit is kept within `FRONT_LIMIT` of the
  player's facing, so a heli closing from behind is steered around into view
  instead of loitering in the off-screen rear blind spot.
- **Fire:** must hold `ATTACK_R` for `REACTION_DELAY` before the first volley,
  only fires within `FIRE_FRONT` of the player's facing, and once a volley starts
  it commits to the whole burst before a long cooldown (1.8 to 3.2 s), giving a
  clear shoot/pause rhythm to dodge.
- **Death:** falls and spins trailing fire and smoke, then explodes with a small
  area blast. Damage smoke ramps as HP drops.

## 6. Mission objectives

Two layers cooperate, both keyed off the JSON contract:

- **Decoded objective block (visualization).** Each `assets/stageMP.json` carries
  an `objectives` block (`destroy`, `rescue`, `special_end`, `target_classes`,
  `n_target_entities`) derived by `decode_level.py` from the phase flag byte and
  the placed entities. `world.lua` collects the matching entities at load and
  `renderer.lua` draws the on-map markers (destroy reticles, POW rings, white
  radar dots) and the objective banner in the stage viewer. No hand authoring
  required; covers all 20 stages.
- **Hand-authored missions (win/lose).** `data/missions.json` maps a stage name
  to a richer def driving the live win/lose simulation. A stage without an entry
  falls back to the decoded block, so every stage has a win condition in both
  single player and co-op.

Once every objective is met, the player must fly the surviving people home and
land on the friendly base pad to complete the phase. The pad is auto-detected
from `basecirc.bin` (or the `h.bin` heliport stamped on it in missions 0 and 3)
unless `home_base_asset` overrides it.

```jsonc
{
  "stage01": {
    "briefing": "Rescue the POWs, level the radar, return to base.",
    "vehicle": "tank",                 // optional: force the vehicle; locks the
                                       // equip screen to it (no switch button)
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

      // sabotage: land on a pad to send an agent into the matched building to
      // plant a charge, then recover it. detonate is "individual" or "all";
      // killable makes losing an agent in the open fail the mission.
      { "type": "sabotage", "target": "tentnew.bin",
        "detonate": "all", "killable": true }
    ]
  }
}
```

Matching is by `target` (asset `.bin` filename), `kind` (`kind_name`) and
`min_size`, any of which may be omitted; `optional: true` tracks an objective
without gating the win. Use the debug inspector's `asset` / `sprite` rows to find
the right filename for a target or the base pad.

**Rescue** (`rescue.lua`): each `powhere.bin` building holds POWs and is shielded
from damage until emptied. Landing on its paired `lh.bin` pad for 1.0 s walks the
POWs out one at a time from the building edge nearest the pad; flying off sends
them back inside. POWs can be shot in the open (enemy fire always, friendly fire
only with `Config.friendly_fire_pows`), which drops them from the count and
leaves a body. Clearing a building fades out its marker and pad and unshields it.
Per-building counts come from `rescue_pow_counts`, defaulting to a random 1-3.
Stages that instead place loose `pow.bin` civilians keep the simpler
fly-over/land-near collection.

**Sabotage** (`saboteur.lua`): each `landhere.bin` pad pairs with the nearest
target building, which is shielded from weapons. Landing on the pad sends an
agent walking in to plant a charge. `individual` detonates each building on its
own timer (stage11); `all` holds every building until every charge is planted,
then blows them together (stage13). The agent walks back to its pad to be picked
up; a site clears once its building is destroyed and its agent recovered.

## 7. Split-screen co-op

`F7` from the overview opens the 2P setup (per-player vehicle boxes, global god
mode, friendly fire; each player toggles with their own keys, `SPACE` starts).
The window then divides vertically, each half following its own player camera,
with the shared systems (`combat`, `powerups`, `hud`, `renderer`, `lightfx`)
pointed at each viewport in turn during draw. Audio registers a listener per
half and mixes each sound for whichever player hears it best (section 8). Each half draws the teammate ringed
in the other player's colour (P1 blue, P2 orange) and shows it on the radar; the
two vehicles are y-sorted identically in both halves.

It runs the **same rules as single player**, only with two players contributing.
`Mission.for_stage(world, players, stage_name)` builds one shared objective the
same way for both modes, so they cannot drift apart: either player can satisfy
any objective and either can fly the return-to-base landing. A tank-only phase
locks both setup boxes to the tank. Each player carries their own `lives` and
respawns on the base pad with the stage's progress intact; the mission fails only
when both are down, so a lone survivor can still finish. `R` reloads the stage
before re-entering, like the single-player restart.

What co-op does not share with a campaign phase: it is entered from the overview,
so it uses the free-play weapon lists rather than an equip loadout, and it has no
briefing, shop or phase-to-phase progression. Each player keeps their own score
from kills attributed to `proj.shooter`, and the stats screen shows a column per
player. Controls: P1 WASD + L-Shift / L-Ctrl / Q / E, P2 arrows + R-Shift /
R-Ctrl / Num0 / NumEnter.

## 8. Audio

Two layers. `core/audio.lua` is the mixer and knows nothing about the game;
`game/sound.lua` decides where a sound is and who hears it.

**Events, not clips.** Gameplay never names a WAV. It names an event
(`explosion.large`, `weapon.chaingun`, `voice.mayday`) and `data/audio.json`
maps that to a clip plus its gain, bus, pitch and pitch jitter, retrigger
cooldown, attenuation range, voice cap and callout priority. Two names are
derived rather than listed: a weapon fires `weapon.<weapon_name>` and an
explosion sounds `explosion.<size>`, so adding a weapon or an explosion size
means adding one event, not a call site. An unmapped name plays nothing.

**Reaching the mixer from the simulation.** Simulation code calls
`World:sound(event, x, y)` and `World:say(event)`, the same forwarder shape the
light emitters use, so nothing in `engine/game/` touches `love.audio` and no
audio state is ever read back. Audio is pure presentation and stays out of the
replay checksum; replay verification and `--selftest` run muted because they
fast-forward the clock. See `DETERMINISM.md`.

**Listeners.** The gameplay scene registers one listener per camera every tick
(`GameplayBase:update_audio`). A world sound is mixed for the listener that
hears it loudest, so in split screen an explosion on player 2's side arrives at
player 2's distance and bearing and does not also spend a voice on player 1's
inaudible copy.

**Direction.** Panning is taken in the listener's rotated frame, which is what
the player sees: game mode turns the world so the vehicle faces up, so left on
screen is left in the mix. A source behind the vehicle is placed behind the
listener rather than merely made quiet. Sources are relative to the listener
with OpenAL rolloff off: direction comes from OpenAL, loudness from our own
attenuation, in fixed world units, so zoom, window size and split screen cannot
change how loud anything is. Distance also rolls off the high end through a
lowpass filter, so a far blast goes dull rather than just small.

**Split screen.** Each half's listener carries a `bias` toward its own side of
the stereo image, scaled by `coop_split_pan` (default 0.35, an OPTIONS slider):
directional cues within a half stay intact, but it is immediately obvious which
half a sound belongs to. Each player's own engine loop is placed by that bias
alone and the engine bed is divided by the player count, so two vehicles do not
drown the mix.

**Voices.** Every clip has a pool: idle voices are reused, extra ones cloned up
to a per-clip and a global cap, and beyond that the oldest voice in the pool is
stolen. A per-event cooldown collapses the burst of identical events a cluster
explosion or a held trigger produces into one voice.

**Radio.** Callouts are non-positional and mission critical only (objective
cleared, return to base, mission complete, mayday, the two POW lines). One line
holds the channel at a time: a higher-priority line cuts in, an equal or lower
one is dropped rather than queued, so the radio never runs behind the action.
The effects and engine buses duck for the length of a line.

**Buses.** `sfx`, `voice`, `engine`, `ui` and `music`, each a volume slider on
the OPTIONS AUDIO page under the master volume.

**Music.** The bus, crossfade and scene hooks exist; no tracks ship. Any `.ogg`
or `.mp3` dropped into `assets/music/` is picked up by its bare filename:
`menu` for the main menu, and for a phase the first that exists of
`stage<MP>`, `mission<M>`, `game`.

## 9. Data files

| File | Contents |
|------|----------|
| `assets/stageMP.json` + `assets/stageMP/*.png` | Decoded stages and sprites. Each stage JSON includes an `objectives` block and a per-class `is_target` flag; each PNG is the axis-aligned `frame_base`. Unit classes also export a sibling dead-pose frame the engine derives by name. |
| `data/weapons.json` | Weapon and projectile definitions: per-level upgrades, `short` / `icon`, `ammo_max` / `ammo_pickup`, `alternate_side` / `trail`, flame cone params, and an optional fixed `range` (world px, default 640). Also the enemy weapons (`flak`, `heavy_flak`, `machine_gun`, `rifle`, `tank_cannon`, `homing_missile`, `sgun`). |
| `data/entity_types.json` | Per-kind combat data: hit radius, explosion, weapon, `detection_radius` / `attack_range` / `turn_speed`, `solid`, `collision_radius`, `muzzle_offset`, unit sprite fallbacks and `dead_frame_offset`, two-part `turret_hp` / `turret_explosion`, hangar `ride_linger`. |
| `data/enemy_overrides.json` | Per-sprite enemy weapon overrides (asset filename -> weapon). |
| `data/enemy_fire_rates.json` | Per-stage enemy fire-rate overrides (stage -> asset filename -> shots/sec). |
| `data/enemy_muzzle.json` | Per-sprite forward muzzle offset (asset filename -> px). |
| `data/building_drops.json` | Forced power-up drops on a building's death (asset filename -> pickup kind, e.g. `bunker.bin` -> `medal`). |
| `data/missions.json` | Per-stage win/lose missions (objective list, forced vehicle, base pad, POW counts, short in-game briefing line). See section 6. |
| `data/mission_text.json` | The original per-phase briefings shown on the mission menu, keyed `stage<M><P>` with a `paragraphs` list. Extracted from `MT0.BIN`..`MT4.BIN`. Presentation only. |
| `data/vehicles/*.json` | Player vehicle tuning, live-editable in the sandbox. |
| `data/animations.json` | Named animation clips: explosions, smoke, rotors, projectile sprites, walk cycles, debris. |
| `data/hud.json` | HUD layout and gauge sprites. |
| `data/sounds.json` + `assets/sounds/*.wav` | Imported SFX: ordered categories of `{name, file, label, rate}`; the WAVs are mono 8-bit PCM decoded from the game's IFF 8SVX `SFX/`. |
| `data/audio.json` | Sound events: `name -> {clip, bus, gain, pitch, pitch_var, cooldown, min_dist, max_dist, max_voices, priority}` over a `defaults` block. Hand maintained, unlike the generated `sounds.json`. See section 8. |
| `data/settings.json`, `data/keybinds.json`, `data/highscores.json` | Persisted player state, written to the LOVE save directory at runtime. |
| `assets/fonts/<name>.{png,json}` | Bitmap fonts: one glyph atlas plus per-glyph metrics, `charmap` / `word` mapping, and `mode` (`mask` or `truecolor`). |
| `assets/equip/*.png` + `layout.json` | Equip screen art: re-rendered EQPCHP / EQPTNK backdrops, weapon rows in 3 states, buttons, level pips, gold digits, and every widget's design-space rect. |
| `assets/phend/*.png` + `layout.json` | DESTRUCTION STATS art in the PHASEPAL palette: header, phase digits, the five label strips, the `%` glyph, the `STATNUMS` digit font. |
| `assets/{credits,hiscore,pow,phase,mission,mainmen,hud,effects,player,fullscreen}/` | Per-screen sprite batteries, each exported in its own palette. |

## 10. Building assets

Requires the original game files. Point the Python tools at the extracted
`STAGE0X/` and `data/` directories:

```bash
pip install pillow numpy
python3 tools/export_love2d.py all   # writes assets/stageMP{.json,/*.png}
python3 tools/export_sounds.py       # writes assets/sounds/*.wav + data/sounds.json (from SFX/)
python3 tools/export_equip.py        # writes assets/equip/ (needs assets/fullscreen/)
love .                               # run
love . stage12                       # open a specific stage
```

Generated assets are never committed. See `README.md` for controls and
`research/` for the reverse engineering record.
