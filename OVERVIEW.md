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
  (`F3`) live-edits and saves vehicle parameters. The overview `[V]` picker
  cycles chopper skins 1-3 (the alternate `CHOP*2`/`CHOP*3` art) then the tank;
  co-op players pick independently in the 2P menu.
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
  damaged. On stage12 a `shut.bin` hut co-located with a tank links as a hangar
  (`World:_link_hangar_tanks`): the tank rides out along its `tanktrak` axis to
  fire when the player is near but not facing it, lingers `ride_linger` seconds,
  then ducks back; while hidden it is shielded (skipped by player hit/AoE/lock
  tests) and drawn under the hut, which takes the damage first. Solid entities
  block tank movement and veto helicopter landings;
  player armor takes damage from enemy fire. Flak turrets fire paired
  accelerating animated tracers (`heavy_flak`); enemy tanks fire the plain
  single-tracer `flak`; soldiers fire rifles. Enemy shots spawn a
  `muzzle_offset` ahead of the hull center (a per-kind `type_data` field,
  editable in the panel, or a per-sprite `data/enemy_muzzle.json` override).
  Enemy turrets vary their weapon by
  sprite (`data/enemy_overrides.json`): gun1 fires slow homing missiles, sguntop
  spits fireballs; sgun fireballs flak-burst on impact while tracers fade out.
  GUN1's fire rate is set per stage in `data/enemy_fire_rates.json` (later phases
  fire faster). Enemy helicopters (`engine/game/enemy_heli.lua`) spawn off-screen at the
  stage's `badheli` marker points (one airborne per marker), fly in toward the
  player and circle it, firing one random weapon (chaingun / FFR / homing
  air_to_air / tracers) when lined up; they have a spinning rotor, smoke when hurt
  and fall-and-explode when downed, like the player, and show on the radar as
  pinkish blips. Both the player chopper and the enemy helis cast a runtime ground
  shadow (`engine/game/shadow.lua`): the body sprite masked to a flat translucent black
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
  rescue and destroy phases still run in single player and co-op.
- **Vehicle equip screen (`scenes/equip.lua` + `ui/equip_screen.lua`):** the
  original EQUIP CHOPPER / EQUIP TANK screens, between the briefing's PLAY and
  the live game. The weapon-bay rows are drawn over the re-rendered backdrop in
  their live state (darkened = not owned or not implemented, gold = loaded in
  that bay, normal = owned) with level pips beside each row; bay 1 always
  carries the chain gun. One special weapon loads at a time. Clicking a row
  loads that bay; TANK / CHOP flips the vehicle; OK applies the loadout
  (`app.settings.loadout`) and starts the phase, EXIT returns to the briefing.
  The campaign inventory lives in `game/loadout.lua` (`app.loadout`, reset by
  NEW GAME): per vehicle the owned level per weapon and the bay assignment.
  A NEW GAME run starts owning only the chain gun and rockets/shells with a 0
  medal purse; the shop (below) buys the rest from medals earned in play.
  Single-mission play (the MISSION menu) equips a separate `app.loadout_free`
  seeded with `Loadout.START_MEDALS` (16) to spend in the shop, since there is
  no run to earn them in. `Loadout.active(app)` picks the right one for the
  current mode and both the shop and equip screens share it.
  `luajit tools/sim_equip.lua` drives the whole screen headlessly (clicks,
  states, buttons, vehicle switch) against a stubbed love API.
  In game the loadout becomes the weapon list (unique bay weapons in bay
  order, then the special): number keys 1-9 select by slot, Q cycles, ammo is
  multiplied by the bay count (N bays of one weapon = N x ammo, the
  original's rule), and each weapon fires at its owned upgrade level (E is
  disabled). Stages with `"vehicle": "tank"` in `missions.json` lock the
  screen to the tank with no switch button, like the original's tank-only
  phases. Weapons not yet in `data/weapons.json` (air strike, the tank
  specials, super napalm) show permanently darkened on the equip screen.
- **Weapon shop (`ui/shop_screen.lua`, `scenes/shop.lua`):** the briefing's
  SHOP button opens the `POWUP` (chopper) / `POWUPT` (tank) shop. Each weapon
  category's three baked icon boxes are its level buttons: an owned level wears
  a gold ring, an affordable level is bright, and a level costing more medals
  than the purse holds is dimmed. Any level can be bought directly (no need to
  own the lower ones first) for `Loadout.PRICES` (2 / 4 / 6 medals for level 1 /
  2 / 3) from the shared purse drawn top-left; the CHOP / TANK toggle flips the
  shopped vehicle (hidden on a forced-vehicle phase) and the DONE button
  (POWGADS) returns to the briefing. Purchases land in the same `owned` table
  the equip screen equips from. Campaign medals accumulate into the purse from
  each phase's pickups (`gameplay.on_stats_done`). The medal / label / icon
  widgets are decoded in the shop runtime palette by `tools/export_shop.py`
  (see below). `luajit tools/sim_shop.lua` drives the screen headlessly.
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

Love2D entry point is `main.lua`: it builds the shared systems into an `app`
context table, registers the scenes with the stack-based scene manager
(`core/scene_manager.lua`), and delegates every `love.*` callback to the
fullscreen fade overlay plus the top scene. Each top-level mode is a scene in
`engine/scenes/`:

- **title** -> **main_menu**: the boot flow; the menu is also pushed over a
  running game (Esc), where RESUME pops back.
- **credits** / **hiscores**: the CREDITS and HIGH SCORES info screens (shared
  `ui/info_screen.lua` shell: backdrop, one-shot title zoom-in, EXIT button).
  The high-score table persists to `data/highscores.json`; a game-over score
  that makes the top 10 opens a name-entry row.
- **advanced_settings** (OPTIONS entry): the options screen edited live over
  the menu backdrop, with pages for visual effects, audio, the EXTRAS, DISPLAY
  (fullscreen / window size / vsync / FPS), and the rebindable CONTROLS; changes
  persist through `core/config.lua` (`data/settings.json`, `data/keybinds.json`).
- **overview** (EDITOR entry): free-roam camera over the stage, stage/kind
  pickers, the SETUP/START/EDITOR/VIEW panel, and the mode-launch keys. The
  entity editor (the shared `dev/debug_panel.lua`) is always on here (not F2
  gated): click an entity to edit its kind.
- **mission_briefing** / **mission_select**: the pre-mission menu and the
  debug mission/phase picker.
- **equip**: the vehicle select and equip screen between the briefing's PLAY
  and the game (skipped when `assets/equip/` is not exported).
- **shop**: the briefing's SHOP button opens the `POWUP` / `POWUPT` weapon
  shop, buying weapon levels with medals into the shared loadout.
- **gameplay** (`F1`): camera locks to the player, world rotates so the player
  faces up, combat runs. **sandbox** (`F3`) extends it with a live
  vehicle-parameter editor.
- **coop_setup** / **coop_gameplay** (`F7`): the 2P setup overlay and the
  split-screen co-op mode.
- **anim_gallery** / **font_gallery** / **sound_gallery** (`F8`/`F9`/`F10`):
  dev test overlays. The sound gallery lists every imported SFX by category
  (packed into columns to fit any window height) and plays (▶) / stops (■) it on
  click.

Engine modules (`engine/`), all built on the tiny `core/class.lua` helper:

| Module | Responsibility |
|--------|----------------|
| `game/world.lua` | Loads a stage JSON, instantiates entities (including per-stage unit alive/dead images), owns the entity list, ground color, the per-mission night flag (`shadows_enabled`, off on the volcanic mission 3), y-sorting, the friendly-base spawn point (`player_start`, detected from `basecirc.bin`/`h.bin`), the solid-entity collision query (`blocked`), the objective entity lists (`targets`, `rescue_zones`, `rescue_people`, `land_zones` for `lh.bin` rescue pads, `objectives`), the enemy-helicopter spawn markers (`heli_spawns`, collected from placed `enemy_helicopter` entities which are never drawn), and the shared explosion shrapnel + ground-dust systems (`spawn_debris`, `add_ground_dust`). |
| `game/entity.lua` | One world object: HP, state machine (idle/animating/exploding/dead), damage smoke, hit effects, destruction crater. Loads shared type data from `data/entity_types.json`. |
| `game/player.lua` | Player vehicle: movement and collision, altitude/landing state (chopper only), independent tank turret, fuel, sprite frame selection per speed/strafe, weapon selection state. The rotor sheets (`bladep`/`bladeb`) are 8-frame spin cycles grouped by pitch/bank position; the active group tracks the hull tilt and only its 8 frames spin, so the blades rotate smoothly. The chopper casts a ground shadow (`draw_shadow`, plus `draw_remote_shadow` for the co-op teammate seen in the other camera) that slides out and fades in with altitude. `chopper_skin` (1 green / 2 blue / 3 desert) picks the body clips (`choppit{n}`/`chopbnk{n}`/`chopdrp{n}`); skins 2 and 3 are the `CHOP*2`/`CHOP*3` art shipped but never selectable in the original (their pixels index the 224-255 palette region, exported under the `VSELECT` vehicle-select palette), exposed here as playable variants. |
| `game/enemy_heli.lua` | Airborne enemy helicopters: spawns them off-screen at the stage's `badheli` markers (`World.heli_spawns`, count = simultaneous cap), flies them toward the player and circles, fires one random weapon when the nose lines up, smokes when damaged, and falls/explodes when downed. They cast ground shadows (`draw_shadows`) like the player. Its live list is exposed as `world.air_units` for `combat.lua` hit detection. |
| `game/combat.lua` | Weapons, projectiles, firing geometry (spread/streams/swing/side offset), hit detection, AoE. Loads `data/weapons.json`. Tracer weapons resolve their streak sprite to the loaded stage's mission variant (`trace`/`strace`/`jtrace`/`rtrace`). The `bomb_drop` weapon glides forward then falls and detonates with shrapnel + full-damage AoE. Homing missiles (player `locking` levels, enemy `homing` weapons) steer toward a target at a capped `turn_rate` so they can be dodged (`_steer_homing`). |
| `core/camera.lua` | Zoom, pan, world-rotation transform, viewport culling, game-mode vertical focus offset (`view_oy`, `screen_center`). |
| `game/renderer.lua` | Draws world layers bottom-to-top in two passes: a ground pass (`draw_ground`: ground dust, decals, segments, destruction craters) and an object pass (`draw_objects`: objects y-sorted and culled, objective markers, grid). The gameplay scene draws a grounded vehicle (the tank) between the two so the object layer stands over it; `draw_objects(mode)` splits objects by solidity so only tall props (trees, buildings, turrets, marked `solid`) occlude the tank while flat clutter (scenery, decals, foot units) stays under it. A chopper is airborne and keeps its slot on top of everything. Non-gameplay scenes call `draw_objects()` (no mode) for the original single-pass order. Flying shrapnel is a separate overlay (`draw_debris`) drawn after the explosion effects. |
| `ui/hud.lua` | Sprite-based gauges, weapon icon, acceleration box, and radar from `data/hud.json`. The radar draws dots by priority (buildings, then enemies, then airborne helicopters in pink from `world.air_units`, then objectives on top in white) so the goal is never hidden. The acceleration box uses the original `BOX.BIN` art with a green dot driven by speed/strafe plus a small turn nudge. Per mission it prefers override art in `assets/hud/stage{m}/` when present (mission 3 ships a full custom armour/fuel/weapons/scanner/box set, 1-2 only armour), falling back per item to the shared `assets/hud/` set (`Hud:set_mission`). A global `Config.hud_scale` grows every element and its edge inset together so corner-anchored items stay in their corners. The `number` item type draws bitmap-font counters (CHARS gold digits via `engine/core/font.lua`) with an optional marker sprite, either trailing the icon or (with `text_on_icon` + `text_dx`/`text_dy`) placed in a slot inside it: score (top-left, `SCORE` marker + 8 digits), lives (top-right before fuel, `LIVES` marker + 1 digit), carried POWs (bottom-left, the `POWCOUNT` "[soldier] POW =" plate with the count in its bottom-right slot, shown only while POWs are aboard the vehicle), and current-weapon ammo (the count in the weapon sprite's own `x` slot, hidden when infinite; `relative_to: "weapon"` pins it to the weapon item's offset so it rides along when the weapon sprite is repositioned). A kill streak (`Player:register_kill`, several kills inside a short window) shows the blinking stage `OVERKILL` word. |
| `game/powerups.lua` | Power-up drops from destroyed large buildings: spawn, ttl/blink, fly-over vs land-on collection, and effect application. Frames from the `pickup` clip. Honors `Config.axis_aligned_pickups` (draws them screen-upright, like the original engine, instead of rotating with the world). |
| `game/mission.lua` | Per-stage win conditions: destroy / rescue / sabotage objectives, progress tracking, and the return-to-base landing requirement. Data-driven from `data/missions.json`, falling back to the stage's own decoded `objectives` block when a stage has no explicit entry (so single player and co-op share the same goals). POWHERE rescue objectives delegate their progress to `rescue.lua`; loose-civilian rescue stages keep the simple fly-over collection. `rescue_pow_counts` (per stage) sets exact POWs per building. |
| `game/rescue.lua` | POW rescue from POWHERE buildings: pairs each `powhere.bin` marker with the nearest `lh.bin` land pad and with the destructible building directly under it (any co-located `structure`, e.g. `bunker2.bin`/`powhut.bin`, paired like a tank hull under its turret) which it shields from damage while the building still holds POWs. Landing on the pad for 1.0s sends POWs (`newdude0`/`pow0`/`pow1` walk clips, rotated to face their path) out one by one from the building edge nearest the pad (so they appear beside, not on top of, the building) to the vehicle (rescued on contact, added to `Player.pows`); leaving sends them back inside. The land pad fades out the moment a vehicle sits on it and fades back in if the vehicle leaves before the building is emptied. A POW can be shot in the open (enemy fire always, friendly fire only with `Config.friendly_fire_pows`), which drops it from the required count and leaves a dead-soldier body (`soldier_dead` pose) on the ground like a felled soldier. Emptying a building fades out its marker and land pad and unshields the building. The POWHERE marker and its land pad are the only in-world cue (no reticle ring). Land pads honor `Config.axis_aligned_pickups` like power-ups. POW counts come from `Mission.rescue_counts` (per-building) or a random 1-3. |
| `core/animation.lua` | Shared immutable `AnimClip` definitions plus per-instance `AnimState` playback. Loads `data/animations.json`. |
| `core/audio.lua` | Minimal sound manager. Loads the catalog `data/sounds.json` (ordered categories of `{name, file, label, rate}`, produced by `tools/export_sounds.py`), creates `love.audio` sources lazily, and plays a clip by name (`Audio.play`), retriggering from the start on repeat. A missing catalog is a no-op so the app still runs before sounds are exported. Used by the sound gallery (`scenes/sound_gallery.lua`). |
| `game/shadow.lua` | Helicopter ground shadows: one light model (sun fixed at the top-left of the unrotated world, so shadows fall to the bottom-right and swing with the world rotation) and a `draw` helper that masks the body sprite to a flat black silhouette. Used by `player.lua` (screen space, offset scaled by draw size) and `enemy_heli.lua` (world space); both scale offset and opacity by altitude and skip night missions (`World:shadows_enabled`). |
| `core/config.lua` | Optional compatibility / gameplay tuning shared across systems, set from the overview SETUP panel before launching a level. `axis_aligned_pickups` keeps pickups (and POW rescue land pads) screen-upright; `friendly_fire_pows` lets the player's own fire kill walking POWs; `hud_scale` scales the on-screen HUD (each element and its inset from the screen edge) toward the chunkier DOS size; `speed_scale` is a global multiplier on gameplay motion (player/heli/enemy movement and turning, projectile and homing speeds) applied at each motion-integration site, deliberately leaving animation playback unscaled so the game looks the same at a different pace. The advanced options screen (`scenes/advanced_settings.lua`, from the menu OPTIONS entry) edits a wider persisted subset live: visual effects (`effects_flashes`, `flash_intensity`, `night_lighting`, `night_brightness`), `master_volume` (applied via `Audio.set_master`), the EXTRAS (see `EXTRA.md`), display (`fullscreen`, `vsync`, `window_size`, `show_fps`, applied via `core/display.lua`), and the key bindings. `Config.load`/`Config.save` persist the scalar keys in `PERSISTED` to `data/settings.json` (booleans, numbers, and strings). |
| `core/screen.lua` | Fullscreen image overlay with fade-in / hold / fade-out (one at a time): the `TITLE` card at launch, the per-mission briefing picture (`STAGE0X_MPIC`) before a level starts, and the crash end screen (`DEATHPIC` chopper / `TANKEND` tank). Images live in `assets/fullscreen/`. |
| `core/input.lua` | Central rebindable key map for the single-player gameplay actions (movement, strafe/turret modifier, fire, takeoff/land, cycle weapon, pause). Each action holds a list of keys (defaults keep both WASD and arrows); `held`/`pressed` query it, `rebind` sets a single key, `reset` restores defaults, and it persists to `data/keybinds.json`. The gameplay scene points the player's `controls` at this map and matches the action keys; the `CONTROLS` page of the advanced options edits it live. Co-op keeps its own per-player key sets and does not use this. |
| `core/display.lua` | Window mode applied through `love.window`: windowed size presets (`Display.SIZES`), fullscreen (desktop), and vsync, read from the persisted `Config` keys (`window_size`, `fullscreen`, `vsync`). `apply()` runs at startup and whenever the advanced options DISPLAY page changes one. The game letterboxes to any size via `ui/layout.lua`, so any window is safe. |
| `ui/end_stats.lua` | End-of-phase DESTRUCTION STATS screen over the dimmed game once the chopper lands home (mission `won`). Header `PHASE n` (`PHEND` art + the `PHASENUM` metallic digit) and `DESTRUCTION STATS` title, then five tallied lines: ground forces / buildings as a percentage destroyed, choppers shot down, POWs rescued, and a provisional OK rating (one point per fully cleared category), with a running `TOTAL SCORE`. Each line animates over its value while a proportional row of `KILLICON` icons (max 10 = 100% / full tally) tracks it and the bonus folds into the score; the OK line shows the spinning `OKBADGE` (each frame centered, since the rotation frames vary in width). `Config.endstats_count_up` builds the values up from zero (default) or counts them down to zero like the original. Co-op shows two value columns per line, one per player in their HUD color (the `STATNUMS` white digit set tinted; the gold set is used single player), from each player's own attributed kills (`combat.lua` / `enemy_heli.lua` credit the shooter's `stat_kills`) against the shared stage totals; the kill-icon rows are single-player only. Assets are built by `tools/export_phend.py` into `assets/phend/` (label strips, `STATNUMS` digit font, header, phase digits) in the `PHASEPAL` palette. A key snaps the tally to its end, the next dismisses back to the overview. |
| `ui/pointer.lua` | Shared mouse/touch pointer for the non-game screens: draws the original `SELPOINT` cursor (`assets/hud/selpoint_f00.png`) at the OS pointer and converts window pixels into the 320x240 design space (`Pointer.to_design`) using the same letterbox transform the menus draw with, so they can hit-test widgets against exactly what they render. Wired from `main.lua`'s mouse/touch callbacks; the OS cursor is hidden while a non-game screen is up. The main menu (`menu.lua`) is hover-to-focus with press/release confirming an entry; the mission menu (`ui/mission_menu.lua`) and mission-select (`ui/mission_select.lua`) give each button a `SELFOCUS` focus ring, swap to a pressed (down) frame while held, and fire the action only on release over the same button (a confirm fade-through-black plays first). Touch mirrors the mouse (the finger is the pointer, so the cursor sprite is suppressed). The cursor is not drawn over passive image overlays (title / briefing / crash screens). |
| `ui/menu.lua` | Main-menu widget over the `MAINP` backdrop: entries (NEW GAME / RESUME / OPTIONS / CREDITS / HIGH SCORES / LOAD / MISSION / EDITOR / EXIT) rendered from the `mainmen` bitmap font with the original arrow cursor, hover-to-focus with press/release confirm, disabled entries dimmed. |
| `ui/mission_menu.lua` | Pre-mission briefing menu over the `STAGE0X_MS` backdrop: the phase selectors, the SAVE / LOAD / SHOP / PLAY / EXIT button row (`assets/mission/`, pressed frames + `SELFOCUS` focus ring), the objective icon column, and the original briefing paragraphs from `data/mission_text.json`. |
| `ui/info_screen.lua` | Shared shell for the CREDITS / HIGH SCORES scenes: fullscreen backdrop, one-shot title zoom-in animation, caller-supplied body content in the 320x240 design space, and an EXIT button; fades in on open and through black on confirm. |
| `ui/equip_screen.lua` | The EQUIP CHOPPER / EQUIP TANK widget layer: draws the re-rendered backdrop, every weapon row in its live state, level pips, specials, and the OK / EXIT / TANK|CHOP buttons from `assets/equip/layout.json` (`tools/export_equip.py`); hit-tests clicks against the same rects, edits the passed `Loadout` in place, and confirms OK / EXIT through the shared fade (`on_select`). A weapon without a `data/weapons.json` def draws darkened and is unselectable. |
| `ui/mission_select.lua` | Debug mission/phase picker reached from the main menu's MISSION entry (which replaced the disabled SAVE). Over the `MAINP` backdrop with its breathing zoom, subtly tinted toward the selected mission's colour (auto-sampled from the average of its `STAGE0X_MPIC` and normalized to shift hue not brightness, eased between missions): a `STAGE0X_MPIC` carousel that slides on a mission change with the clicked arrow bumping (scale), a row of the four `PHASE 0X` buttons (`assets/mission/phase0X`, the selected shows its pressed frame) used like PLAY / EXIT, and PLAY / EXIT. Keyboard-first: up/down move focus between the carousel / phase / button rows, left/right act within a row (cycle mission / pick phase / pick button), 1-4 jump to a phase, Enter plays, Esc exits; the focused element is outlined (a 1px primitive rect around the big carousel box, the `SELFOCUS` ring around the small phase/button widgets). Mouse and touch also work. PLAY loads the chosen `stageMP` (`World:load` -> `after_stage_load`) and opens its pre-mission menu (`ui/mission_menu.lua`); EXIT returns to the main menu. Title in `chars`; tint strength is `TINT_AMOUNT`. |
| `core/font.lua` | Original bitmap fonts (`assets/fonts/<name>.{png,json}`, exported by `tools/export_fonts.py`). Each font is one atlas plus per-glyph quad metrics; `Font.get(name)` caches an instance and `print` / `print_word` draw a string at a scale and tint color. Most glyph containers are ordinary blitter sprite frames (one frame per glyph) and decode through `decode_blitter`; the in-game body fonts `chars`/`charspow` are the raw planar HUD class and decode through `decode_planar` (the exporter routes each font automatically by `decode_planar.is_planar`). Their pixels are a brightness ramp in a high palette region the stage palette leaves undefined, so the exporter renders them as white-on-alpha intensity **masks** (gradient preserved by rank-normalizing the ramp) that the engine tints at runtime. `OVERKILL` keeps its real per-stage palette (truecolor, drawn untinted); `charstit` is the yellow-with-outline title font (truecolor under GOVPAL, idx 16 outline + idx 24 `(252,220,0)`) used for the mission-menu descriptions; `mainmen` is the main-menu word art sliced per letter and packed by `tools/export_mainmen.py` (truecolor, the whole menu renders from it). Truecolor fonts keep their baked RGB but still honor a passed alpha so the menu can fade/blink/dim them. Full sets (`chars`/`charspow`/`charstit`/`hichars`/`hichars2`/`savechar`/`endchars`/`keysfont`) are ASCII-indexed (frame == codepoint); `phasenum` is the digits `1234`; `gov`/`gov2`/`overkill` are word sequences. The `F9` gallery renders every font for testing. |
| `dev/debug_panel.lua` | Entity editor / debug overlay: click to select an entity (overlap pick-list), inspect it, and edit every `type_data` field (numbers step, bools toggle, string fields cycle known values). Mouse-driven: each field row has clickable `-`/`+` steppers and the actions (play animation / fire weapon / kill / revive / save) are clickable buttons; keyboard edits still work. Entities with a weapon get a `FIRE` action (`F`) that shoots one round of their weapon via `combat:fire_entity`; the overview ticks and draws `combat` so the shot flies and bursts. Clickable rects are rebuilt each frame as hit zones (`_zone`/`_zone_at`) and consumed before the world-pick fallthrough. `[S]` / the Save button write all fields per kind to `data/entity_types.json`. Always on in the overview (the editor); still F2-toggled in gameplay. While the pick-list / picker / field editor is open the overview camera is held still (`captures_arrows`) and the focused overlapping entity glows in the world (`highlight_entity`). |
| `core/mathx.lua` | Small math helpers shared across systems: the `atan2` LuaJIT/Lua 5.3 shim and `heading_deg` (screen heading in the deg 0 = north, clockwise-positive convention). |
| `core/scene.lua` | Base class for scenes: no-op lifecycle hooks (`enter`/`leave`/`suspend`/`resume`), update/draw, and input handlers; `ui_pointer = true` marks menu-family scenes that own the SELPOINT cursor. |
| `core/scene_manager.lua` | Stack-based scene manager: name registry (`register`), `switch`/`push`/`pop`/`replace`, and `dispatch` to the top scene only. Scenes address each other by name so they never require each other in cycles. |
| `game/vehicles.lua` | Vehicle catalogue shared by the scenes: per-vehicle weapon cycle lists, the equip-screen bay/special weapon lists (`BAY_WEAPONS`/`SPECIAL_WEAPONS`/`BAY_COUNT`), the chopper-skin/tank picker cycle, and UI labels. |
| `game/loadout.lua` | Campaign weapon inventory (`app.loadout`, reset by NEW GAME): per vehicle the owned level per weapon, the bay assignments (bay 1 fixed chain gun), and the loaded special; `weapon_list` builds the gameplay list with bay-count ammo multipliers and owned levels. The shop (`ui/shop_screen.lua`) buys levels into `owned` with medals via `Loadout:buy`; `Loadout.active(app)` returns the campaign or MISSION-mode inventory. |
| `game/weather.lua` | Weather overlay: a world-space tiled field of pixel particles (snow on the winter mission, rain on the jungle mission) drawn through the camera so flying streams it and turning rotates it; density stays uniform under any pan/turn. Activated per stage by `GameplayBase:enter_weather`. |
| `game/stats.lua` | Destruction-stats bookkeeping shared by gameplay and the end-of-phase screen: the ground/building kind tables, `kind_category`, `destructible_totals`, and `stage_phase`. |
| `ui/layout.lua` | Shared 320x240 design space (`DESIGN_W`/`DESIGN_H`) and the `fit` letterbox transform (scale + centering offsets) used by every non-game screen and `ui/pointer.lua`. |

Scene modules (`engine/scenes/`), one per top-level mode, all subclassing
`core/scene.lua`: `title`, `main_menu`, `advanced_settings` (the OPTIONS
screen), `credits`, `hiscores`,
`mission_briefing`, `mission_select`, `equip`, `shop`,
`overview`, `gameplay_base` (shared firing / weapon cycling / landing /
mission-won sequencing), `gameplay`, `sandbox` (extends gameplay; a live
mouse/keyboard player-vehicle editor), `coop_setup`, `coop_gameplay`,
`anim_gallery`, `font_gallery`, `sound_gallery`.

## Game controls

`F1` enters game mode and spawns the vehicle on the friendly base pad; the chopper
lifts off automatically. WASD or arrows drive; the chopper lands / takes off again
with `Space` (it bounces back up if it tries to land on a solid obstacle). Holding `Shift` while turning strafes the chopper or
rotates the tank turret. `Ctrl` fires, `Q` cycles weapon, `1`-`9` select a weapon
slot directly, `E` cycles weapon level (free play only; an equip loadout fixes
each weapon at its owned level).
`F5` toggles unlimited ammo/fuel/armor (god mode); `F6` toggles power-up pickup
between easy (fly-over) and hard (land-on); `R` restarts the current level; `P`
pauses. The overview screen presents a SETUP panel (top-left, in titled boxes):
`V` switches vehicle, `O` toggles optional game-over (death), `C` toggles
axis-aligned vs world-rotated pickups, and `[` / `]` step the `speed_scale`
gameplay-motion multiplier (all of these feed `engine/core/config.lua` and the live
game). `F8` opens the animation gallery: a test overlay that plays every clip in
`data/animations.json` at once in a labelled grid (`Esc`/`F8` to close). `F9`
opens the font gallery: every original bitmap font in `assets/fonts/` rendered
with a sample string, mask fonts tinted gold (`Esc`/`F9` to close).

A fade-in `TITLE` card shows at launch. Pressing `F1` first shows the loaded
stage's briefing picture (`STAGE0X_MPIC`, selected by the mission digit of the
stage name) and then drops into the live game with a short eased zoom-in
(`Camera:start_zoom_intro`); the chopper lifts off the pad once the zoom-in ends.
With game-over enabled, a fatal crash plays the
wreck animation, waits ~3 seconds, then fades up the end picture (`DEATHPIC` for
the chopper, `TANKEND` for the tank). With lives to spare the picture flashes
briefly and the player respawns at the home base with the stage's progress
intact (destroyed enemies stay down, objectives keep their progress); on the
last life the run is over and the final score goes to the high-score screen.
When every
objective is met and the chopper lands at the home base (mission `won`), the
`MISSION COMPLETE` overlay holds ~1.5s and then hands off to the DESTRUCTION
STATS screen (`ui/end_stats.lua`); dismissing it returns to the overview, or in
a campaign run (NEW GAME) carries the accumulated score and remaining lives to
the next phase's briefing, showing the mission picture when a run crosses into
a new mission; clearing the last stage sends the total to the high-score
screen. `Esc` skips the
current picture and returns to the overview, and from game mode it returns to the
overview too; it never quits the game.

## Split-screen co-op

`F7` (viewer only) opens the split-screen co-op setup menu (graphical per-player
vehicle pick in colored boxes, global god mode, friendly fire), an extra mode not
in the original. The menu has no cursor: each player toggles their own vehicle
with their own keys at any time (P1 `A`/`D`, P2 `Left`/`Right`), `G` toggles god
mode, `F` toggles friendly fire, `SPACE` starts. In split screen the window
divides vertically, each half follows its own player camera, and the shared
systems (`combat`, `powerups`, `hud`, `renderer`) are pointed at each viewport's
camera/player in turn during draw. Each half draws the teammate via
`Player:draw_remote` (positioned with `Camera:project`) ringed in the other
player's color (P1 blue, P2 orange) and shows it on the radar (`hud.coplayer`);
the two vehicles are y-sorted so the southern one draws on top, identically in
both halves.

It is co-op: a single shared objective is built from the stage's decoded
`objectives` block via `Mission.coop` (destroy all `world.targets` / rescue
`world.rescue_people`, then any player returns to base; fail only when both are
down). Each player keeps an own `score` (kills attributed to `proj.shooter` in
`CombatSystem`). Friendly fire (`combat.friendly_fire`, default off) lets a
player's rounds hit the other. P1 uses WASD + L-Shift/L-Ctrl/Q/E, P2 uses arrows
+ R-Shift/R-Ctrl/Num0/NumEnter; `Player.controls` holds the per-player bindings
(`combat.players` / `powerups.players` carry both). `F5` toggles god for both,
`R` restarts, `Esc`/`F1` exits.

## Combat system map

- `combat.lua` owns weapons, projectiles, and transient `effects` (missile trails,
  napalm fire). `fire()` builds projectiles from a weapon def and a level index,
  applying spread, multiple streams, swing, perpendicular side offsets, and
  `alternate_side`; `proj_type "flame"` routes to `_fire_flame` (a damaging fire
  cone) instead. `update()` advances/culls projectiles + effects (effects apply a
  one-time AoE) and runs hit detection; `_check_hit` is split player-vs-entity and
  enemy-vs-player and honors `player.unlimited`.
- `powerups.lua` spawns pickups when `entity.drop_powerup` is set (large building
  death), and applies ammo/fuel/armor/medal effects on collection.
- Enemy turrets sharing the `flak_turret` kind fire different weapons per sprite
  via `data/enemy_overrides.json` (asset filename -> weapon), applied to
  `entity.weapon` at load; the AI reads `e.weapon or td.weapon`. Enemy rounds play
  their `explosion` clip on death (`_end_projectile`), except tracers which fade.
- Two-part objects (tank hull+turret, radar base+dish) are folded at load via
  `TURRET_DEFS` in `world.lua`; a turret with `spin` rotates on its own (radar),
  otherwise the AI aims it. `data/building_drops.json` forces a pickup kind on a
  building's death (asset filename -> kind, e.g. bunker -> medal).
- Player ammo lives on `player.lua` (`seed_ammo`/`has_ammo`/`consume_ammo`/
  `add_ammo`); the scenes' `fire_for` (`scenes/gameplay_base.lua`) gates on it. Weapons map to a `short` name and
  WEAPONS.BIN `icon` frame in `data/weapons.json`.
- `GameplayBase:fire_for` (`engine/scenes/gameplay_base.lua`) drives player firing from input and the weapon's fire rate.
- `entity.lua` is the damage target: `take_damage`, `on_hit` (spawns smoke),
  the HP-tier damage smoke, and the death/explosion state machine.
- `data/weapons.json` defines every weapon, including `enemy` weapons (`flak`,
  `machine_gun`, `tank_cannon`, `rifle`) that have no firing code yet.
- `data/entity_types.json` already carries `weapon`, `attack_range`,
  `detection_radius`, and `turn_speed` for enemy kinds. Enemy AI is the natural
  next consumer of these fields.

When extending combat, keep the player and enemy paths symmetric where it makes
sense, and route all projectile spawning through `combat:fire` so geometry stays
in one place.

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
| `data/entity_types.json` | Per-kind combat data (hit radius, explosion, weapon, ranges, `solid`, `collision_radius`, `muzzle_offset`, unit `sprite`/`dead_sprite` fallback clips, `dead_frame_offset` for the per-stage corpse frame, two-part tank `turret_hp`/`turret_explosion`, hangar-tank `ride_linger`). |
| `data/enemy_overrides.json` | Per-sprite enemy weapon overrides (asset filename -> weapon), for turrets that share the `flak_turret` kind but fire different weapons. |
| `data/enemy_fire_rates.json` | Per-stage enemy fire-rate overrides (stage name -> asset filename -> shots/sec), e.g. GUN1 firing faster in later mission-0 phases. |
| `data/enemy_muzzle.json` | Per-sprite forward muzzle offset (asset filename -> px) so enemy shots leave the barrel instead of the hull center. |
| `data/building_drops.json` | Forced power-up drops on a building's destruction (asset filename -> pickup kind, e.g. `bunker.bin` -> `medal`). |
| `data/missions.json` | Optional per-stage win/lose missions (objective list + return-to-base). See "Mission objectives". Empty by default; the auto-decoded `objectives` block in each stage JSON drives the on-map markers and banner without it. Each entry's short `briefing` line is the in-game status-banner text (`mission.lua`), separate from the full mission-menu text below. |
| `data/mission_text.json` | Original per-phase pre-mission briefings shown on the mission menu (`ui/mission_menu.lua`), keyed `stage<M><P>` with a `paragraphs` list (objective, then any enemy/threat notes). Extracted from the game's `MT0.BIN`..`MT4.BIN` by `tools/export_mission_text.py`. Presentation only. |
| `data/vehicles/*.json` | Player vehicle tuning. |
| `data/highscores.json` | Persisted top-10 high-score table (rank / nickname / score), read and written by `scenes/hiscores.lua` (saved to the Love2D save directory at runtime). |
| `data/animations.json` | Named animation clips (explosions, smoke, rotors, projectile sprites). |
| `data/sounds.json` + `assets/sounds/*.wav` | Imported sound effects. The catalog is an ordered list of categories (`weapons`, `vehicle`, `voice`, `ui`, `explosions`, `misc`) of `{name, file, label, rate}`; the WAVs are mono 8-bit PCM decoded from the game's `SFX/` IFF 8SVX files. Built by `tools/export_sounds.py`. Loaded by `engine/core/audio.lua`. |
| `data/hud.json` | HUD layout and gauge sprites. |
| `assets/fonts/<name>.{png,json}` | Original bitmap fonts: one glyph atlas plus per-glyph metrics (`x,y,w,h,oy,advance`), `charmap`/`word` mapping, and `mode` (`mask` or `truecolor`). Built by `tools/export_fonts.py` from the game's glyph containers. |
| `assets/{credits,hiscore,pow,phase}/*.png` + screen sprites in `assets/hud,effects` | Per-screen sprite batteries built by `tools/export_screens.py`, each in its own palette: the gold main-menu CREDITS/HIGH SCORES titles (MAINP palette, animated in `scenes/credits.lua` / `scenes/hiscores.lua`), the gold weapon-shop widgets (GOVPAL; `powgads` PURCHASE/DONE/CHOP/TANK buttons, `pownames` weapon-category labels, `pownums` digits, `powmedal` medal icons for the POWUP/POWUPT shop screens, plus the in-game `powcount` HUD plate), the OVERKILL badge and kill icon (PHASEPAL), the stage fire (BURN/BURN2, registered as `burn`/`burn2` clips), and the objective briefing cards (PHASE1..4). The `powgads` DONE/CHOP/TANK buttons drive the live `ui/shop_screen.lua`; the shop sprites that need the POWUP/POWUPT runtime palette (`powmedal`, `pownames`, `powarmed`, `powfocus`, `powwgads`) are exported by `tools/export_shop.py`, which reconstructs that palette from the screenshot-derived `assets/fullscreen/POWUP.png` + `POWUPT.png` (backdrop-index sampling, POWWGADS icon-tile alignment for the icon bodies, GOVPAL for indices 0-79). |
| `assets/equip/*.png` + `layout.json` | Vehicle equip screen art built by `tools/export_equip.py`: the re-rendered EQPCHP/EQPTNK backdrops, every weapon row in 3 states (normal / selected / darkened), the OK / EXIT / TANK|CHOP buttons (up / down / blank plate), the lit / empty level pips, and the EQPNUMS gold digits (unused yet). `layout.json` carries every widget's design-space position (template-matched against the backdrop index maps) grouped into bays / specials / buttons. Palette: GOVPAL for indices 0-79, the high region sampled from the exported fullscreen PNGs (interior-pixel mode, median for thin features). Consumed by `ui/equip_screen.lua`. |
| `assets/phend/*.png` + `layout.json` | DESTRUCTION STATS screen art built by `tools/export_phend.py` (PHASEPAL palette): the `header` (`PHEND`), the four `phase_fN` digits (`PHASENUM`), the five line label strips (`PHGTXT`/`PHBTXT`/`PHCTXT`/`PHPTXT`/`PHOTXT`, label cropped off their baked number placeholders), the lifted `pct` "%" glyph, and the `STATNUMS` readout digit font (`digit_f00..09` white, `f10..19` gold). Wired into `ui/end_stats.lua`. The blitter line strips author every line onto one origin and wrap the 384-pixel mode-X back buffer; the exporter unwraps them (rolling x past the widest empty column run) before cropping. |

## Building assets

Requires the original game files. Point the Python tools at the extracted
`STAGE0X/` and `data/` directories:

```bash
pip install pillow numpy
python3 tools/export_love2d.py all   # writes assets/stageMP{.json,/*.png}
python3 tools/export_sounds.py       # writes assets/sounds/*.wav + data/sounds.json (from SFX/)
python3 tools/export_equip.py        # writes assets/equip/ (equip screens; needs assets/fullscreen/)
love .                               # run
love . stage12                       # open a specific stage
```

See `README.md` for controls and `research/` for the reverse engineering record.
