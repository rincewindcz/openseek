# OpenSeek

Lua / Love2D 11.x reimplementation of *Seek & Destroy* (SAFARI Software, DOS,
1993-1995). No original code is reused. Original art, sound and level data are
decoded from the user's own copy of the game and are never distributed.

## 1. Repository layout

| Path | Contents |
|------|----------|
| `main.lua` | Entry point: game data check, shared `app` context, scene registration, `love.*` callbacks. |
| `conf.lua` | Window configuration. |
| `engine/core/` | No game knowledge: class, config, input, rng, display, camera, animation, audio, font, screen, screenshot, scenes, assets, mathx, log. |
| `engine/game/` | Simulation and gameplay presentation systems. |
| `engine/ui/` | Screens and widgets. |
| `engine/scenes/` | One scene per top-level mode. |
| `engine/dev/` | Debug panel, determinism self-test. |
| `lib/` | Vendored `json.lua`. Excluded from lint. |
| `data/` | Hand-maintained JSON tunables. |
| `content/` | Original artwork shipped with the engine. |
| `assets/` | Game data pack decoded from the original files. Not tracked. |
| `tools/` | Python decoders and exporters for the `assets/` pack. |
| `screenshots/` | F12 captures (`seek-<timestamp>.png`), ignored except the `seek_*.png` README images. Fused, web and mobile builds write to `screenshots/` in the save directory. |

## 2. Game data

| Root | Source | Tracked |
|------|--------|---------|
| `assets/` | Exporters in `tools/` run against the original game files. | no |
| `content/` | Original work. | yes |
| `tools/MENUTITLE_PAL.BIN` | Menu-title palette reconstructed from a screenshot and interpolated. Not present in the game files. | yes |

- Data-driven paths resolve through `engine/core/assets.lua`: `content/...` is
  used as is, any other path is prefixed with `assets/`.
- `Assets.pack_present()` checks the files the boot path needs
  (`stage00.json`, `fonts/chars.json`, `fullscreen/TITLE.png`, `sounds.json`,
  `mission_text.json`). If any is missing, `love.load` shows `MISSING GAME DATA`
  and loads nothing else; `Esc` quits; `--selftest` exits with code 1.
- Files in `content/` must not contain pixels copied from the game or from
  `assets/`. Palette-bound sprites are white-on-alpha masks tinted at draw time.

| `content/` file | Notes |
|-----------------|-------|
| `hud/player_f00..f03.png` | Co-op score labels P1-P4, 8x6 masks, 3x5 glyphs. |
| `fonts/main_synth/{B,J,K,Q,Y,Z}.png` | Menu word-art letters absent from `MAINMEN.BIN`. |

## 3. Code conventions

1. **No prerendered rotations.** Draw the axis-aligned frame 0 and rotate with
   `love.graphics.draw`. Never index a rotation arc by angle. Frame selection by
   speed, strafe or state is animation and allowed.
2. **One angle convention.** Degrees, 0 = north, clockwise positive. Velocity or
   aim: `rad = (angle - 90) * pi / 180`. Frame-0 draw rotation: `angle * pi / 180`.
   The camera applies the inverse rotation in game mode.
3. **Data over hardcoding.** Tunables live in `data/*.json` with code defaults.
4. **ASCII only** in code, comments and strings.
5. **Comments only for non-obvious context.**
6. **Extras are toggleable.** A behavior change inside a classic phase that the
   original lacks needs: a `Config` boolean (defaults table and `PERSISTED` in
   `core/config.lua`), a row on the `EXTRAS` page of
   `scenes/advanced_settings.lua`, an `EXTRA (<key>)` code comment, a row in
   section 11, and a `Replay.PARAMS` entry if it affects simulation.
7. **Deterministic simulation.** Simulation code reads no wall clock, keyboard,
   window size, camera zoom or `math.random`; presentation never writes
   simulation state.

Style:

- Plain Lua 5.1 (love.js compatible): no `goto`, no `bit` / `ffi`, no 5.2+ syntax.
- 4 spaces, no tabs. Align `=` within contiguous assignment blocks. Soft limit
  ~100 columns.
- `require` lines first, then module locals. Literal require paths only.
- Section headers are a plain `-- name` line.
- Missing assets degrade (no-op `AnimState`, skipped nil image), never error mid-frame.
- Check `love.filesystem.getInfo(path)` before `read`, `newImage`, `newImageData`,
  `newSource` or `newSoundData` on any path that may not exist. In love.js the
  exception LOVE raises for a missing file aborts the page; `pcall` does not
  catch it.
- Files `snake_case.lua`; classes `PascalCase`; functions and fields
  `snake_case`; constants `UPPER_SNAKE`; private members `_prefixed`.
- Allowed abbreviations: `dt`, `x y w h`, `dx dy`, `hp`, `i j k v`, `g = love.graphics`.
- Classes via `core/class.lua` (`Foo = Class()`, `Foo:init`, `Foo:new`) for
  anything with instances or lifecycle; plain module tables for stateless helpers.
- Console output through `core/log.lua` (`Log.info(tag, fmt, ...)`,
  `Log.warn`): scene changes, phase and mission events, saves, missing files.
  Never per tick or per frame; simulation files must not read the clock for it.
- JSON through `lib/json.lua` and `love.filesystem.read`. Images load once, via
  `core/animation.lua` caches or the per-stage cache in `game/world.lua`.

## 4. Verification

```bash
luacheck .                    # zero warnings required
love . --selftest [ticks] [stage]
love . [stageMP]
```

| Check | Run after touching |
|-------|--------------------|
| `--selftest` | any simulation code |

## 5. Architecture

`main.lua` builds `app` (world, camera, renderer, combat, hud, screen fade, end
stats, settings, scene manager) and passes it to every scene. `love.update`
advances `fixed_step` scenes in whole 1/60 s ticks, catch-up clamped to 5 ticks;
other scenes get the frame delta.

Scenes (`engine/scenes/`, base `core/scene.lua`, stack manager
`core/scene_manager.lua`):

- Navigation only through `app.scenes:switch/push/pop/replace(name, ...)`; scenes
  never require each other.
- Only the top scene receives update, draw and input. Pause is a flag inside
  gameplay scenes.
- The `Screen` fade overlay is app-level: updated first, drawn last, gates input.
- `ui_pointer = true` hides the OS cursor and draws the `SELPOINT` sprite.
- Touch goes to the scene's `touchpressed/touchmoved/touchreleased` first; a hook
  returning false passes it on to the mouse handlers. Mouse events synthesized
  from touches (`istouch`) are ignored.

| Scene | Role |
|-------|------|
| `title` | TITLE card; Enter, Space, Esc skip to `main_menu`. |
| `main_menu` | Main menu; pushed over a running game on Esc. NEW GAME replaces it with `new_game`. |
| `new_game` | NEW GAME mode menu: SOLO CAMPAIGN, LOCAL COOP, CANCEL (`mainmen` has no B J K Q Y Z). |
| `vehicle_select` | Per-player CHOPPER and TANK variant cards over the unused original `VSELECT` art (preview boxes, camo strips, OK / EXIT plates) with turntable previews. Campaign: START begins the run. Free (F7): the focused card is the vehicle; G / F toggle god mode and friendly fire. |
| `credits`, `hiscores` | Info screens over `ui/info_screen.lua`; top-10 table with name entry, one per qualifying player after a co-op run. |
| `advanced_settings` | OPTIONS: DISPLAY, VIDEO, EFFECTS, AUDIO, CONTROLS, GAMEPLAY, EXTRAS. Rows scroll when a category holds more than `MAX_ROWS` (9); CONTROLS rows carry two key columns. |
| `mission_briefing` | Briefing text, phase selectors, SAVE / LOAD / SHOP / PLAY. |
| `mission_select` | Debug mission / phase picker with a separate medal purse. |
| `equip` | Vehicle and weapon-bay selection; skipped without `assets/equip/`. One special is always loaded. Co-op: once per player (tagged), EXIT steps back a player. |
| `shop` | POWUP / POWUPT weapon shop. Co-op: once per player, each with their own purse. |
| `overview` | Free camera, stage and kind pickers, entity type editor. |
| `gameplay` (F1) | Player-locked rotating camera, combat. |
| `sandbox` (F3) | Gameplay plus live vehicle parameter editor. |
| `coop_gameplay` (F7, LOCAL COOP) | Split-screen two-player co-op; full screen when one player is left in a campaign. |
| `replays` (F4) | Play back, verify, toggle recording, delete. |
| `saves` | SAVE / LOAD slots over the green-tinted `MAINP` backdrop: unlimited named slots, scrolling, name entry, two-step delete. Opened from the briefing (both modes) and from the menu LOAD entry. |
| `anim_gallery`, `font_gallery`, `sound_gallery` (F8/F9/F10) | Asset galleries. |

`scenes/gameplay_base.lua` is shared by the three gameplay scenes: firing,
weapon cycling, landing, tick accounting, mission-won sequencing.

| Module | Responsibility |
|--------|----------------|
| `core/camera` | Zoom, pan, world rotation, culling, wrap tiles, fixed `game_zoom`. |
| `core/config` | Tuning and compatibility flags; `PERSISTED` keys saved to `data/settings.json`. |
| `core/display` | Window size, fullscreen, vsync, mobile `view_scale`. |
| `core/input` | Rebindable single-player key map (`data/keybinds.json`); two key slots per action (`MAX_KEYS`), short column labels via `key_label`. |
| `core/input_frame` | Per-player tick input: held bitmask + edge events + optional analog turn (`TURN_STEPS` 32). Bit order is replay format. |
| `core/input_source` | `Local` (keyboard per tick), `Replay`, `Remote` (stub). |
| `core/rng` | Seeded per-phase RNG with draw counter. |
| `core/animation` | `AnimClip` from `data/animations.json`, per-instance `AnimState`. |
| `core/assets` | Path resolution and pack check (section 2). |
| `core/audio` | Clip catalog, event table, voice pools, buses, ducking, music. |
| `core/font` | Bitmap fonts from `assets/fonts/`; mask (tinted) or truecolor. `print` `cell` option draws fixed-pitch at each glyph's in-frame x offset. |
| `core/screen` | Fullscreen image fade in / hold / out. |
| `core/mathx` | `atan2` shim, `heading_deg`. |
| `core/log` | Timestamped, tagged console lines (`info`, `warn`). |
| `game/world` | Stage load, entities, ground colour, collision (`blocked`), objectives, shrapnel, dust, `world.time`, `world.rng`, `world.params`. |
| `game/entity` | HP, state machine, damage smoke, hit effects, crater. |
| `game/player` | Movement, collision, altitude, landing, tank turret, fuel, frames, rotors, ammo, death, skins, score, lives. `Player.draw_tank_variant` is shared with the select screen. |
| `game/enemy_heli` | Enemy helicopter spawn, flight AI, fire, death (`world.air_units`). |
| `game/combat` | Weapons, projectiles, firing geometry, hits, AoE, effects, ground enemy AI. |
| `game/mission` | Objectives, progress, return to base. `Mission.for_stage(world, players, stage)`. |
| `game/rescue` | POW rescue from `powhere.bin` buildings. |
| `game/saboteur` | Sabotage objective. |
| `game/powerups` | Drops from large buildings: ttl, blink, fly-over pickup unless the difficulty says to land on it (medals, fuel / armor); `F6` forces fly-over for everything. |
| `game/difficulty` | Difficulty presets over the difficulty Config keys (`data/difficulty.json`): choices, apply, match. |
| `game/renderer` | Ground pass, object pass (y-sorted, culled), player layer by `is_airborne()`, shrapnel overlay. |
| `game/lightfx` | Night light map, additive flashes. |
| `game/postfx` | World-view post-processing and soft shadows (`data/postfx.json`). |
| `game/impact_fx` | EXTRA hit flash and camera shake (`data/impact_fx.json`), fed by the `World:hit_flash` / `:player_hit` / `:explosion_light` / `:player_death_light` forwarders; the shake is a per-camera offset applied in `Camera:apply`. |
| `game/sound` | Listeners, panning, attenuation, engine loops, radio queue. |
| `game/shadow` | Altitude-scaled silhouette shadows, off at night. |
| `game/weather` | Snow (mission 1), rain (mission 2). Presentation, global RNG. |
| `game/vehicles` | Free-play weapon cycles, equip bay and special lists, variants (`data/vehicle_variants.json`, loaded on first use), labels. |
| `game/campaign` | NEW GAME run state: solo run fields or `app.coop_run` (per-player score, lives, threshold, out flag, `Loadout`; lives rule and pool), active players, `advance`, `finish`. |
| `game/loadout` | Campaign inventory: levels, bays, special (always one, the vehicle's first by default), ammo multipliers, `buy`. `Loadout.info` (cost, description lines) from `assets/pow/weapon_info.json`; `price` = list cost minus `trade_in` (`data/shop.json`) of the owned level's cost. `Loadout.active(app, player)` picks a co-op player's own. |
| `game/score` | Kill values, phase bonus weights, bonus-life ladder, `Score.award`. |
| `game/stats` | Destruction categories and stage totals. |
| `game/replay` | Replay header, delta input, checksums, `.osr` files. |
| `game/savegame` | Campaign save slots: capture / apply a run (stage, score, lives, bonus ladder, whole inventory; co-op adds a `coop` table per player), one JSON file per slot in `saves/`. |
| `ui/hud` | Gauges, weapon icon, radar, counters, OVERKILL banner, rolling score. |
| `ui/end_stats` | DESTRUCTION STATS screen; per-player columns in co-op. |
| `ui/equip_screen` | Equip widgets over `assets/equip/layout.json`. |
| `ui/shop_screen` | Original shop flow over `data/shop.json`: select a level icon (description, trade-in COST), PURCHASE buys it. LOADED on the owned level, lower levels darkened and unselectable, medal purse bottom-left (digits, large medal per 10, small per 1). Arrows move over the grid, Enter purchases, Tab switches vehicle, Esc is DONE. `shop_fx` (EXTRA.md) animates the purse. |
| `ui/menu` | Main menu over `MAINP`, `mainmen` font. |
| `ui/player_tag` | Co-op player colours, `PLAYER n` badge for the shop / equip screens. |
| `ui/mission_menu` | Briefing menu, button row, objective icons, `assets/mission_text.json`. |
| `ui/mission_select` | `STAGE0X_MPIC` carousel, phase buttons. |
| `ui/info_screen` | CREDITS / HIGH SCORES shell. |
| `ui/pointer` | Mouse / touch pointer in 320x240 design space. |
| `ui/layout` | 320x240 design space, letterbox `fit`. |
| `ui/touch_controls` | Single-player on-screen controls: floating stick (left half), FIRE, STRAFE, LAND, WEAPON, MENU. Held state and analog `turn()` read by `InputSource.Local`, buttons queue edge events. Stick angle from vertical: straight within 8 deg, turn rate linear to full at sideways, drives within 65 deg of up/down, dead zone 0.25 of the radius. Drawn while the last input was touch. |
| `dev/debug_panel` | Entity inspector and type editor, saves `data/entity_types.json`. F2 in gameplay. |
| `dev/selftest` | Scripted phase run three ways, compared per tick. |

## 6. World and coordinates

- World units are original pixels. World is `world_size` square (normally 4096).
- The map is a torus: positions wrap, draw passes tile per map copy
  (`Camera:tiles`), distances use `World:delta`. Projectiles use unbounded
  coordinates, culled by range or ttl.
- Mission 0 phases 0-2 inset content ~48 px; `World:_fit_wrap_period` shrinks
  `world_size` to the content width.
- Stages hold 4500-8200 entities, mostly static props. Per-tick scans use
  subsets built in `World:load` instead of `world.entities`:
  - `world.hittable`: entities with `hit_radius > 0`. Projectile hits, blasts,
    lock-on, crush, player death blast.
  - `world.droppers`: entities with `drop_kind` or `crater_eligible`. Power-up drops.
  - `world.decal_index` / `world.object_index`: load-time y of the y-sorted
    `decals` / `objects`. `World.each_in_y` (renderer passes, craters) and
    `World:blocked` binary-search it and check `mobile` entities (patrol and
    hangar tanks) separately, in list order.
  - `world.updaters`: entities with hit points, a route or a turret. Other
    entities (`prop`) join `world.awake` through `World:wake` when an explosion,
    animation, hit smoke or corpse slide starts on them, and leave when it ends.
    `World:update` runs updaters, then awake props. Exact because an entity
    update touches only its own state and props draw no random numbers.
  - Adding entities or moving a non-`mobile` entity after load requires
    rebuilding these.
- The HUD radar caches its entity subset per entity list.
- The renderer draws ground (dust, decals, segments, craters), then objects.
  Tank and landed chopper draw between passes; airborne chopper above objects and
  enemy flyers.

## 7. Combat

- `CombatSystem:fire` builds projectiles from a weapon def and level: spread,
  streams, swing, side offsets, `alternate_side`. `proj_type "flame"` is a damage
  cone; `bomb_drop` glides then detonates with shrapnel.
- Player range 640 px unless the weapon sets `range`.
- Projectiles carry `owner`. Homing steers at capped `turn_rate`.
- Player ammo: `seed_ammo`, `has_ammo`, `consume_ammo`, `add_ammo`; gated in
  `GameplayBase:fire_for`. All spawning goes through `combat:fire`.
- Weapons flagged `shadow` cast shadows only with soft shadows on.

Ground combatants: any type with `weapon` and `detection_radius > 0`.

| Kind | Weapon | Detect | Attack | Turn deg/s | Reaction s | Moves |
|------|--------|-------:|-------:|-----------:|-----------:|-------|
| soldier | rifle | 280 | 220 | 100 | 0.7 | no |
| soldier_aggressive | rifle | 320 | 240 | 150 | 0.4 | no |
| flak_turret | heavy_flak | 320 | 240 | 120 | 0.6 | no |
| tank | flak | 360 | 260 | 70 | 0.9 | routes, 28 px/s |

- Targets nearest live player in `detection_radius`, turns at `turn_speed`, waits
  `reaction_delay` (reset on leaving), fires within `LOCK_DEG` 8 and
  `attack_range`. Cadence from weapon or `data/enemy_fire_rates.json`.
- `muzzle_offset` per kind or `data/enemy_muzzle.json`. Per-sprite weapon from
  `data/enemy_overrides.json`.
- Two-part units (tank + `*tanktop`, radar + dish) fold at load (`TURRET_DEFS`).
  Turret absorbs damage and dies first.
- Patrol tanks ease between waypoints and stop before each shot.
- Hangar tanks (stage12): `shut.bin` hut + tank link (`World:_link_hangar_tanks`).
  Tank rides out along `tanktrak`, lingers `ride_linger`, returns. Hidden tank is
  untargetable and drawn under the hut.

Enemy helicopters (`enemy_heli.lua`): spawned at off-screen `badheli` markers,
one per `SPAWN_DELAY` 2.5 s, capped at marker count. `SPEED` 110, `TURN_RATE`
120, `ORBIT_R` 270, `ATTACK_R` 360, `FIRE_CONE` 32, `MAX_HP` 60, `BLAST_RADIUS`
70, `BLAST_DAMAGE` 40, `REACTION_DELAY` 0.9, `FRONT_LIMIT` 90, `FIRE_FRONT` 115.
Weapon from `WEAPON_POOL` (chaingun burst 3, homing_missile, air_to_air level 2,
machine_gun burst 4). Approaches beyond `ORBIT_R * 1.25`, otherwise orbits within
`FRONT_LIMIT` of the player's facing. Full burst then 1.8-3.2 s cooldown.

## 8. Missions

- Each `assets/stageMP.json` has a decoded `objectives` block (`destroy`,
  `rescue`, `special_end`, `target_classes`, `n_target_entities`) used for markers
  and as fallback win condition.
- `data/missions.json` overrides per stage. After all objectives the player lands
  on the base pad (`basecirc.bin`, or `h.bin` in missions 0 and 3, or
  `home_base_asset`).

```jsonc
{
  "stage01": {
    "briefing": "short in-game line",
    "vehicle": "tank",              // optional, locks equip screen
    "home_radius": 48,
    "home_base_asset": "lh.bin",    // optional
    "rescue_pow_counts": [3, 2],    // optional, per powhere.bin in load order; default random 1-3
    "objectives": [
      { "type": "destroy", "target": "radar.bin", "count": "all" },
      { "type": "destroy", "kind": "structure", "min_size": 28, "count": 5, "label": "..." },
      { "type": "rescue", "target": "pow.bin", "radius": 40, "count": 4 },
      { "type": "sabotage", "target": "tentnew.bin", "detonate": "all", "killable": true }
    ]
  }
}
```

- Match fields: `target` (asset filename), `kind`, `min_size`; `optional: true`
  does not gate the win.
- Rescue: `powhere.bin` buildings are shielded until empty. Landing 1.0 s on the
  paired `lh.bin` pad walks POWs out; leaving sends them back. POWs die to enemy
  fire, to player fire only with `friendly_fire_pows`. Loose `pow.bin` uses
  fly-over or land-near pickup.
- Sabotage: `landhere.bin` pad pairs with the nearest target building (shielded).
  Landing sends an agent to plant. `individual` detonates per building (stage11);
  `all` waits for every charge (stage13). Site clears when destroyed and agent
  recovered.
- `special_end` (stage43) is a label only.

## 9. Co-op

- NEW GAME > LOCAL COOP: a campaign for two. Vehicle select (a chopper and a
  tank variant per player), then the solo flow: briefing, SHOP and equip once
  per player, each with their own medals, owned weapons and bays. Score, lives,
  bonus threshold and medals carry per player; SAVE / LOAD store both players.
- Lives (`coop_lives`, read when the run starts): `separate` spare vehicles per
  player, or one `shared` pool (6 at start, bonus vehicles join it, capped at
  `Score.MAX_LIVES`) that every player's lives mirror. A crashed player respawns
  only if a vehicle is left beyond those the teammates still fly. Without one
  they are out for the rest of the run; the next phase spawns only the rest,
  full screen when one is left. All out: crash picture, then a high-score
  entry per qualifying player.
- F7 free play: vehicle select in free mode (the focused card is the vehicle, G
  god mode, F friendly fire), full weapon lists, no briefing, shop or
  progression, back to the menu after the stats.
- Vertical split, camera and HUD per half, shared systems drawn per viewport.
  Same rules as single player via `Mission.for_stage`; either player completes
  any objective. The landing is the whole team's: once the objectives are done,
  every player still flying has to be parked on the home pad
  (`Mission:player_home`), and a half already parked blinks WAIT FOR TEAMMATE. A
  wrecked or out player is not waited for; going down on the way home only wins
  the phase when nobody is left to fly it home. Respawn on the base pad; failure
  when both are down. Per-player score, bonus threshold and stats column, credited by
  `proj.shooter`.
- Slots (input, replay) follow spawn order; `p.number` is the player (colour,
  keys, HUD label). The replay header stores it, and the lives rule.
- P1: WASD, L-Shift, L-Ctrl, Q, E. P2: arrows, R-Shift, R-Ctrl, Num0, NumEnter.
  Select screen: P1 W/S card, A/D variant; P2 arrows; Enter start, Esc back.

## 9a. Vehicle variants

`data/vehicle_variants.json`, index = skin number (config, co-op settings,
replay header `player.N.skin` / `player.N.tank`).

| Vehicle | Variants | Art |
|---------|----------|-----|
| Chopper | GREEN, ARCTIC, DESERT | `CHOP*1..3` player sets (2 and 3 unused in the original). |
| Tank | GREEN, DESERT, ARCTIC, STEEL, RUST | Player `TANKBGRN` / `TANKTOP`; enemy hull + turret pairs from stage01 (`tank` / `tanktop`), stage11 (`stank`), stage21 (`jtank`), stage31 (`tank` / `tankt2`, night palette). |

- Tank fields: `hull` / `turret` clips (`vtank_*` in `data/animations.json`),
  `hull_anchor` / `turret_anchor` pivots from the stage `render` offsets
  (enemy turrets sit on the hull pivot), `barrels` as `{ lateral, forward }`
  art px from the turret pivot. Shells cycle through the variant's barrels
  (1 to 3), so they are simulation input.
- Enemy hulls have one frame: no tread animation. No night sets for enemy
  variants; they draw the day art at night.
- `camo` (1-4) is the VSELECT strip the select screen draws; `camo_tint`
  recolours it.

## 10. Audio

- Gameplay names events (`explosion.large`, `weapon.chaingun`, `voice.mayday`);
  `data/audio.json` maps them to clip, bus, gain, pitch, pitch_var, cooldown,
  min/max distance, max_voices, priority over `defaults`. `weapon.<name>` and
  `explosion.<size>` are derived. Unmapped events are silent.
- Mixed for the loudest listener (one per camera). Panning in the rotated view
  frame; sources behind the vehicle placed behind the listener. OpenAL rolloff
  off; attenuation and lowpass in fixed world units.
- Split screen: per-half `bias` scaled by `coop_split_pan` (default 0.35); engine
  bed divided by player count.
- Voice pools per clip with per-clip and global caps; oldest voice stolen.
  Per-event cooldown.
- Radio: one line at a time; higher priority interrupts, equal or lower dropped;
  sfx and engine buses duck.
- Buses: `sfx`, `voice`, `engine`, `ui`, `music`.
- Music: `.ogg` / `.mp3` in `assets/music/`: `menu`, then per phase the first of
  `stage<MP>`, `mission<M>`, `game`. No tracks are produced by the tools.

## 11. Additions beyond the original

Toggleable extras (EXTRAS page):

| Key | Default | Effect |
|-----|---------|--------|
| `explosive_trees` | on | Tank at speed destroys trees for a small armor cost. |
| `tree_crush_speed` | 0.7 | Fraction of top speed required. |
| `hit_flash` | off | Damaged armed enemies flash white (`game/impact_fx`). |
| `camera_shake`, `camera_shake_amount` | off, 1.0 | Explosions and hits near the camera shake the view, scaled by the amount (`game/impact_fx`). |

Options:

| Keys | Page | Effect |
|------|------|--------|
| `night_lighting`, `night_brightness` | VIDEO | Night ambient, headlight cone, explosion and muzzle lights. |
| `effects_flashes`, `flash_intensity` | VIDEO | Additive flashes and screen washes. |
| `postfx_enabled`, `postfx_preset`, `postfx_grade`, `postfx_contrast`, `postfx_sharpen`, `postfx_bloom`, `postfx_vignette`, `postfx_grain`, `postfx_soft_shadows` | EFFECTS | World-view shader (HUD excluded). Presets NONE / MILD / FULL; soft shadows add rotor, smoke and missile shadows. |
| `speed_scale` | GAMEPLAY | Motion multiplier; animation unscaled. |
| `hud_scale` | GAMEPLAY | HUD size and inset. |
| `axis_aligned_pickups` | GAMEPLAY | Screen-upright pickups and pads, as the original. |
| `friendly_fire_pows` | GAMEPLAY | Player rounds kill POWs and saboteurs. |
| `endstats_count_up` | GAMEPLAY | Stats count up instead of down. |
| `score_count_up` | GAMEPLAY | HUD score rolls to new total (frame time, presentation). |
| `shop_fx` | GAMEPLAY | Animated shop medal purse (presentation). |
| `difficulty`, `enemy_damage`, `enemy_fire_rate`, `enemy_aggression`, `land_for_medals`, `land_for_supplies` | DIFFICULTY | The original's EASY / MEDIUM / HARD (`game/difficulty`, `data/difficulty.json`), each value also editable (preset then reads CUSTOM). Multipliers on enemy damage to the player, enemy fire rate, and aggression (detection and attack range up, reaction delay down); HARD is 1.0 on all, the engine's own tuning. MEDIUM needs a landing to collect medals, HARD also fuel and armor. Replay parameters; replays from before them apply HARD multipliers with no landing rules (`Replay.LEGACY_PARAMS`). |
| `chopper_skin`, `tank_skin` | GAMEPLAY | Solo chopper and tank variants (section 9a); also set by the vehicle select screen and the overview `V` cycle. Recorded in the replay header. |
| `coop_lives` | GAMEPLAY | Co-op campaign lives: `separate` or `shared` pool (section 9). |
| `master_volume`, `sfx_volume`, `engine_volume`, `voice_volume`, `ui_volume`, `music_volume` | AUDIO | Master and bus volumes. |
| `audio_positional` | AUDIO | Directional mix; off centres all sounds. |
| `coop_split_pan` | AUDIO | Split-screen stereo bias. |
| `voice_callouts` | AUDIO | Radio callouts. |
| `fullscreen`, `vsync`, `window_size`, `show_fps` | DISPLAY | Window mode, letterboxing. |
| `data/keybinds.json` | CONTROLS | Rebindable gameplay actions. |

Modes and tools: split-screen co-op (free play and campaign), vehicle select
screen (unused `VSELECT` art), replays, chopper skins 2 and 3 (`CHOP*2`,
`CHOP*3`, unused in the original), tank variants from the enemy tanks, runtime
sprite rotation, weather, runtime
shadows, shrapnel / dust / craters, overview type editor, vehicle sandbox, asset
galleries, debug mission picker, headless checks.

## 12. Data files

| File | Contents |
|------|----------|
| `data/weapons.json` | Player and enemy weapons: levels, `short`, `icon`, `ammo_max`, `ammo_pickup`, `alternate_side`, `trail`, flame params, `range`, `shadow`. |
| `data/entity_types.json` | Per kind: hit radius, explosion, weapon, detection / attack / turn, `solid`, `collision_radius`, `muzzle_offset`, sprite fallbacks, `dead_frame_offset`, `turret_hp`, `turret_explosion`, `ride_linger`. |
| `data/enemy_overrides.json` | Asset filename -> weapon. |
| `data/enemy_fire_rates.json` | Stage -> asset filename -> shots/s. |
| `data/enemy_muzzle.json` | Asset filename -> muzzle px. |
| `data/building_drops.json` | Asset filename -> forced pickup kind. |
| `data/missions.json` | Section 9. |
| `data/vehicles/*.json` | Vehicle tuning (sandbox editable). |
| `data/vehicle_variants.json` | Chopper and tank variants (section 9a). |
| `data/animations.json` | Named animation clips. |
| `data/hud.json` | HUD layout; sprite paths through `core/assets`. |
| `data/audio.json` | Sound events. |
| `data/postfx.json` | `look` (100% values) and `presets`. |
| `data/difficulty.json` | EASY / MEDIUM / HARD presets: values for each difficulty key. |
| `data/impact_fx.json` | Hit flash time / strength; camera shake per explosion size, player hit and player death (amount in world units, time, radius). |
| `data/shop.json` | Shop `trade_in` share and screen layout: backdrops, box grid, category placement per vehicle, button / COST / purse / description positions, sprite offsets, darkened level tile per weapon level (`powwgads` chopper, `powgadst` tank); `fx` timings for `shop_fx`. |
| `data/settings.json`, `data/keybinds.json`, `data/highscores.json` | Defaults; written to the save directory. |
| `saves/save-<timestamp>-<n>.json` | One campaign save slot each, written to the save directory only (`game/savegame.lua`). |
| `assets/stageMP.json`, `assets/stageMP/*.png` | Stages; one frame-0 PNG per class, `render` offsets, `objectives`, `is_target`. |
| `assets/sounds.json`, `assets/sounds/*.wav` | Clip catalog (categories of `{name, file, label, rate}`), mono 8-bit WAV. |
| `assets/mission_text.json` | `stage<M><P>` -> `paragraphs`. |
| `assets/fonts/<name>.{png,json}` | Atlas + glyph metrics, `charmap` or `word`, `mode` `mask` / `truecolor`. |
| `assets/equip/`, `assets/phend/` | Screen art + `layout.json` rects. |
| `assets/pow/weapon_info.json` | Shop catalogue: vehicle -> weapon -> per level `{cost, lines}` (upper-cased description), from `WINF.BIN` / `WINFT.BIN`. |
| `assets/{credits,hiscore,pow,phase,mission,mainmen,hud,effects,player,fullscreen}/` | Per-screen sprites. |

## 13. Tools

Requires Python 3, `pillow`, `numpy`. Game directory via `--game-dir`.

| Tool | Output |
|------|--------|
| `export_love2d.py all` | `assets/stageMP.json`, `assets/stageMP/` |
| `export_projectiles.py` | `assets/stage00/` projectiles |
| `export_player.py` | `assets/player/` |
| `export_hud.py` | `assets/hud/` |
| `export_animations.py` | `assets/effects/` |
| `export_fonts.py` | `assets/fonts/` (`overkill0`..`overkill4`: one OVERKILL banner per mission in its stage palette) |
| `export_mainmen.py` | `assets/mainmen/`, `assets/mainmen/font/`, `assets/fonts/mainmen.*` (palette from `MAINMEN.BMP`) |
| `menutitle.py` | `tools/MENUTITLE_PAL.BIN` (needs a CREDITS screenshot) |
| `export_screens.py` | CREDANIM / HIANIM, POWCOUNT, OKBADGE, KILLICON, BURN, PHASE cards |
| `export_mission.py` | `assets/mission/` |
| `export_mission_text.py` | `assets/mission_text.json` |
| `export_sounds.py [SFX dir]` | `assets/sounds/`, `assets/sounds.json` |
| `export_phend.py` | `assets/phend/` |
| `export_shop.py` | `assets/pow/` sprites, `assets/pow/weapon_info.json` (WINF / WINFT prices and descriptions), `assets/fonts/charspow.*` in the shop palette (palette from `assets/fullscreen/POWUP*.png` plus screenshot-measured indices and the darkened-tile grey ramp; run after `export_fonts.py`) |
| `export_equip.py` | `assets/equip/` (needs `assets/fullscreen/EQP*.png`) |
| `decode_fullscreen_v2.py` | Fullscreen PNG; palette from `--dosbox-ref` screenshot, else embedded block x4 (wrong colours) |
| `decode_level.py` | Stage BIN -> JSON (`--summary`) |
| `decode_blitter.py` | Exact world-sprite decoder |
| `decode_planar.py` | Exact planar HUD sprite decoder (`--pal-offset 14` for fullscreen palettes) |
| `decode_palette.py`, `decode_sincos.py`, `decode_stage_assets.py`, `decode_font.py`, `decode_fullscreen.py` | Viewers / dumps |

## 14. Controls

| Key | Action |
|-----|--------|
| WASD / arrows | Drive / pan |
| Shift + turn | Strafe chopper / rotate tank turret |
| Ctrl | Fire |
| Space | Take off / land |
| Q, 1-9 | Cycle / select weapon |
| E | Weapon level (free play) |
| P | Pause |
| R | Restart stage |
| F1 | Game mode |
| F2 | Debug inspector |
| F3 | Sandbox |
| F4 | Replays |
| F5 | God mode |
| F6 | Fly-over pickup override (ignores the difficulty landing rules) |
| F7 | Co-op free play (vehicle select) |
| F8 / F9 / F10 | Animation / font / sound gallery |
| F12 | Screenshot (rebindable) |
| Overview: wheel, +/- | Zoom |
| Overview: Tab, PgUp/PgDn | Stage picker / cycle |
| Overview: L, G | Segment lines, 256 px grid |
| Overview: V, O | Vehicle, optional game over |
| Overview: C, [ ] | Axis-aligned pickups, `speed_scale` |
| Overview: S | Save `data/entity_types.json` |
| Esc | Back (menu in game) |
| Touch | Stick: drive. Buttons: FIRE, STRAFE (modifier), LAND, WEAPON, MENU. Tap commits a high-score name. |

On the web build (`love.system.getOS() == "Web"`) the window is not resizable;
the page scales the 1280x720 canvas to the viewport. Lowpass filters are skipped
when `love.audio.isEffectsSupported()` is false.

`usedpiscale` is off (`conf.lua`, `Display.apply`): units are pixels on every
platform. On Android and iOS `Display.view_scale()` (screen height / 720)
multiplies the camera zoom, the player sprite scale (`Camera:zoom_ratio`) and
the HUD scale. PostFX shaders request `highp` on OpenGL ES; `effect` parameters
stay `mediump` (LOVE's prototype) and the texture coordinate comes from
`VaryingTexCoord`.
