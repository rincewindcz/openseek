# OpenSeek

Lua / Love2D 11.x reimplementation of *Seek & Destroy* (SAFARI Software, DOS,
1993-1995). No original code is reused. Original art, sound and level data are
decoded from the user's own copy of the game and are never distributed.

## 1. Repository layout

| Path | Contents |
|------|----------|
| `main.lua` | Entry point: game data check, shared `app` context, scene registration, `love.*` callbacks. |
| `conf.lua` | Window configuration; the window icon `content/icon/openseek.png` (not on Windows, where the exe carries the icon, nor on the web). |
| `engine/core/` | No game knowledge: class, config, input, gamepad, mouse stick, rng, display, camera, animation, audio, font, screen, screenshot, scenes, assets, flic, mathx, log. |
| `engine/game/` | Simulation and gameplay presentation systems. |
| `engine/ui/` | Screens and widgets. |
| `engine/scenes/` | One scene per top-level mode. |
| `engine/dev/` | Debug panel, determinism self-test, photo mode. |
| `lib/` | Vendored `json.lua`. Excluded from lint. |
| `data/` | Hand-maintained JSON tunables. |
| `content/` | Original artwork shipped with the engine, including the icon (`content/icon/openseek.svg`, rendered to `openseek.png`). |
| `assets/` | Game data pack decoded from the original files. Not tracked. |
| `tools/` | Python decoders and exporters for the `assets/` pack. |
| `screenshots/` | F12 captures (`seek-<timestamp>.png`), ignored except the `seek_*.png` README images. Fused, web and mobile builds write to `screenshots/` in the save directory. |

## 2. Game data

| Root | Source | Tracked |
|------|--------|---------|
| `assets/` | `tools/build_pack.py` run against the original game files. | no |
| `content/` | Original work. | yes |

- Data-driven paths resolve through `engine/core/assets.lua`: `content/...` is
  used as is, any other path is prefixed with `assets/`.
- The pack is built on the user's machine, never distributed. Release builds
  convert into `assets/` in the LOVE save directory, which LOVE searches before
  the source, so the same paths resolve. A developer checkout may keep
  `assets/` in the repo root instead.
- `assets/manifest.json` (written by `build_pack.py`): `schema`, `edition`
  (`shareware` / `registered`), `missions` (0-1 or 0-4), `failed` exporter
  steps, `source` (`download` or the converted path).
- `Assets.pack_status()`: `missing` if a file the boot path needs is absent
  (`stage00.json`, `fonts/chars.json`, `fullscreen/TITLE.png`, `sounds.json`,
  `mission_text.json`), `outdated` if `manifest.schema ~= Assets.SCHEMA`, else
  `ok`. A pack without a manifest is accepted (developer export).
- Not `ok`: `love.load` loads nothing else and hands the callbacks to
  `ui/data_setup.lua`. It plays the engine intro card, dims it behind
  `MISSING GAME DATA` / `GAME DATA OUTDATED` in `content/fonts/loaded/loaded.ttf`
  and, on desktop with a converter present, offers `DOWNLOAD SHAREWARE`,
  `USE MY COPY` (typed or pasted path, or a folder / zip dropped on the window),
  `REBUILD GAME DATA` (outdated pack with a recorded source) and `QUIT`. The
  converter runs in a `love.thread` through `io.popen`; its `download N%`,
  `unpack N%` and `[i/n]` step lines drive one bar split equally between the
  phases that run, and `DONE` restarts LOVE (`love.event.quit("restart")`). Converter
  lookup: the `openseek-setup` binary next to the game (the macOS download
  ships it inside the app, beside the `.love`); else `openseek-setup.pyz` next to the game, run by `python/python.exe`
  beside it on Windows when present (the Windows download ships it), else by
  `py -3` / `python3`; else `tools/build_pack.py` in an unfused source checkout. Web and mobile
  only show the label. `--selftest` exits with code 1.
- The number of missions offered follows the stages present
  (`World:mission_count()`): the campaign ends after the last stage and the
  mission picker cycles only those missions. A registered pack plays the
  original's ending there (`scenes/ending.lua`), then the credits, then the
  high scores; the shareware goes straight to the high scores. Vehicle variants whose hull /
  turret (or chopper) frames are not in the pack are dropped from the list
  (`game/vehicles.lua`; the shareware keeps tanks GREEN, DESERT, ARCTIC).
- Files in `content/` must not contain pixels copied from the game or from
  `assets/`. Palette-bound sprites are white-on-alpha masks tinted at draw time.

| `content/` file | Notes |
|-----------------|-------|
| `hud/player_f00..f03.png` | Co-op score labels P1-P4, 8x6 masks, 3x5 glyphs. |
| `fonts/main_synth/{B,J,K,Q,Y,Z}.png` | Menu word-art letters absent from `MAINMEN.BIN`. |
| `intro/openseek_intro.png` | openSEEK engine card, 1920x1080, shown before TITLE (`engine_intro`) and behind `MISSING GAME DATA`. |
| `fonts/loaded/loaded.ttf` | "Loaded" TTF (Andrew Wilson, SIL OFL 1.1, `OFL.txt`). Text fallback when the pack's bitmap fonts are missing. |

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
love . --touch                # phone controls on a desktop (see below)
love . --photo [stageMP]      # developer photo mode (see below)
```

`--touch` turns the left mouse button into a single touch (the pointer moves
only while it is held, as a finger would) and makes `Z` hold the on-screen FIRE
button as a second touch, so the stick and FIRE work together. The controls show
from the start and OPTIONS gains the MOBILE UI page. The OS cursor stays
visible. Other mouse buttons and the keyboard behave as usual.

`--photo` enables photo mode (`dev/photo_mode`), a developer tool for
promotional stills; without the flag the module is never loaded. `F8` in
gameplay, co-op or the overview opens it (the overview's animation gallery key
is taken while the flag is on): the simulation holds as in a pause, the HUD and
every overlay are left out, and the view is free.

| Input | Action |
|-------|--------|
| Left drag | Move the view |
| Wheel | Zoom about the mouse |
| Right drag, `[` / `]` | Turn the view (`turn_step` degrees per key press) |
| `0` | Back to the scene's own framing |
| `V` | Pin the stage view: the stage data's `photo_view` (`x`, `y` at the window center, `scale` in window pixels per world pixel, `turn` in degrees), else the world center, north up, at the game zoom. The same picture in every stage and scene wherever the vehicle is, until the view is moved |
| `O` | Next output size (`outputs` in `data/photo.json`); the frame guide marks what a capture covers |
| `.` | Simulate one tick; held, the scene runs at `slow_motion` speed. Live input still drives the vehicle |
| `Enter`, `F12` | Capture into `screenshots/` |
| `C` | Copy the world position under the mouse to the clipboard |
| `Tab` | Hide the key help |
| `F8`, `Esc` | Leave |

A capture draws the world again into a canvas of the output size, so it can be
larger than the window and of another shape. Texel-sized post-processing steps
(bloom spread, soft shadow blur, sharpen) come out finer in a capture larger
than the window, and precipitation is rolled again for it. Co-op is drawn as
one full-window view from the first player's camera.

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
- `ui_pointer = true` hides the OS cursor and draws the `SELPOINT` sprite;
  `hide_cursor = true` (the ending) hides it with no sprite.
- Touch goes to the scene's `touchpressed/touchmoved/touchreleased` first; a hook
  returning false passes it on to the mouse handlers. Mouse events synthesized
  from touches (`istouch`) are ignored.
- A gamepad button reaches the top scene as `padpressed(pad, button,
  from_stick)`; a trigger pulled and the left stick tipped into a direction
  arrive the same way (`Gamepad.axis_pressed`, the stick as the d-pad button
  with `from_stick`). The base scene turns it into the key it stands for
  (`Gamepad.MENU_KEYS`: d-pad arrows, A / START Enter, B / BACK Esc), which is
  what drives every menu; the gameplay scenes take their bound actions instead.
  The `Screen` overlay is advanced or cancelled (B) first, as by a key.
- An unhandled error ends in `ui/error_screen` (`love.errorhandler`).

| Scene | Role |
|-------|------|
| `title` | Engine intro card on the first launch or while `engine_intro` is on (Enter, Space, Esc skip to TITLE), then the TITLE card; Enter, Space, Esc skip to `main_menu`. |
| `main_menu` | Main menu (NEW GAME, RESUME, OPTIONS, CREDITS, HIGH SCORES, LOAD, ADVANCED, EXIT, or FULLSCREEN on the web); pushed over a running game on Esc, where RESUME pops back to it. Otherwise RESUME reopens the campaign autosave at its briefing. NEW GAME replaces it with `new_game`. |
| `advanced_menu` | ADVANCED submenu, same widget and backdrop: MISSION, REPLAYS, EDITOR, BACK. Keeps the non-run entries off the main menu. |
| `new_game` | NEW GAME mode menu: SOLO CAMPAIGN, LOCAL COOP, CANCEL. |
| `vehicle_select` | Per-player CHOPPER and TANK variant cards over the unused original `VSELECT` art (preview boxes, camo strips, OK / EXIT plates) with turntable previews; the active card names its variant in the gold `credchars` font, its letters closed up by up to 2 px when the name is wider than the gap between the arrows (the co-op columns). Campaign: START begins the run. Free (F7): the focused card is the vehicle; G / F toggle god mode and friendly fire. Two players: a CONTROLS line per column (`1` / `2` or a click cycles AUTO, KEYS, PAD 1, PAD 2 into `coop_device_1` / `_2`, showing what AUTO resolves to and a named pad that is missing); a pad steps the column of the player holding it. |
| `ending` | The original's ending after the last stage (`Campaign.complete`): `assets/ending/reganim.flc` (CD release only) through `core/flic` at `anim.frame_time` with its frame cues and two fading engine loops, then the `ending` music under FIN01..03 and VIC1..3. Each picture fades in, holds, types `assets/ending/ending.json` lines in `fonts/endstory` at fixed 8 px pitch (`char_time` per letter, a tab pauses `tab_pause`), shows the prompt and waits. A key completes the picture's text, then moves on; a key skips the animation; Esc skips everything. `enter{ alternate, record, scores, preview, keep_music, on_done }`; `alternate` types VIC3's alternate ending, `preview` falls back to `data/ending.json` `preview` without a record (overview F11), `keep_music` leaves the end music playing into the credits (`Campaign.complete`). EXTRA `ending_stats` adds the run record under FIN01..03. |
| `credits`, `hiscores` | Info screens over `ui/info_screen.lua`. Credits: `data/credits.json`, openSEEK first in the large style (`main` heading, `credchars` name), then the original team under a gold `hichars` label in the small style (`credchars` heading, `chars` name); `enter(on_exit)` replaces EXIT's return to the menu (the ending passes the high scores). High scores: top-10 table in the gold `credchars` font (`hichars` fallback) with name entry, one per qualifying player after a co-op run. |
| `advanced_settings` | OPTIONS: DISPLAY, VIDEO, EFFECTS, AUDIO, CONTROLS, MOBILE UI, GAMEPLAY, DIFFICULTY, EXTRAS. MOBILE UI only where `TouchControls.available` (web, Android, iOS, `--touch`); the web build drops DISPLAY's FULLSCREEN and WINDOW SIZE. The sidebar packs tighter when it holds more than nine entries. Rows scroll when a category holds more than `MAX_ROWS` (9). CONTROLS: a DEVICE row switches the action rows between KEYBOARD and GAMEPAD, each with two binding columns (Enter captures the next key or pad button, Del clears a slot), RESET TO DEFAULTS restores the shown device, then STICK DEAD ZONE, MOUSE STEERING and MOUSE SPEED. |
| `mission_briefing` | Briefing text, phase selectors, SAVE / LOAD / SHOP / PLAY. Rewrites the autosave on every open in a campaign run. |
| `mission_select` | Debug mission / phase picker with a separate medal purse. |
| `equip` | Vehicle and weapon-bay selection; skipped without `assets/equip/`. One special is always loaded. Co-op: once per player (tagged), EXIT steps back a player. |
| `shop` | POWUP / POWUPT weapon shop. Co-op: once per player, each with their own purse. |
| `overview` | Free camera, stage and kind pickers, entity type editor. |
| `gameplay` (F1) | Player-locked rotating camera, combat. |
| `sandbox` (F3) | Gameplay plus live vehicle parameter editor. |
| `coop_gameplay` (F7, LOCAL COOP) | Split-screen two-player co-op; full screen when one player is left in a campaign. |
| `replays` (F4) | Dev replay panel over the overview: play back, verify, toggle recording, delete. |
| `replay_select` | REPLAYS screen (menu ADVANCED), built like `saves` over a blue-tinted `MAINP`: watch a recording, two-step delete, left / right (or the label) step the order between newest, oldest and by progress, stage / mode / players / running time of the highlighted one, flagged when it was recorded on an older build. Playback returns here through `app.replay_return`. |
| `saves` | SAVE / LOAD slots over the green-tinted `MAINP` backdrop: unlimited named slots, scrolling, name entry, two-step delete. Opened from the briefing (both modes) and from the menu LOAD entry. |
| `anim_gallery`, `font_gallery`, `sound_gallery` (F8/F9/F10) | Asset galleries. |

`scenes/gameplay_base.lua` is shared by the three gameplay scenes: firing,
weapon cycling, landing, tick accounting, mission-won sequencing.

| Module | Responsibility |
|--------|----------------|
| `core/camera` | Zoom, pan, world rotation, culling, wrap tiles, fixed `game_zoom`. |
| `core/config` | Tuning and compatibility flags; `PERSISTED` keys saved to `data/settings.json`. |
| `core/display` | Window size, fullscreen, vsync, mobile `view_scale`. |
| `core/input` | Rebindable action maps per device (`data/keybinds.json`): `Input.map` for the keyboard (single player), `Input.pad_map` for gamepad buttons (single player and co-op; stored under `"pad"`, an action may be empty). Two slots per action (`MAX_KEYS`), short column labels via `key_label`. |
| `core/input_frame` | Per-player tick input: held bitmask + edge events + optional analog turn (`TURN_STEPS` 32). Bit order is replay format. |
| `core/input_source` | `Local` (keyboard per tick, plus a list of devices answering `held(action)` and `turn()`: touch controls, gamepad, mouse stick; the first analog `turn()` wins), `Replay`, `Remote` (stub). |
| `core/gamepad` | Gamepads (SDL-mapped controllers only, numbered in connection order, refreshed on `joystickadded` / `joystickremoved`). `Gamepad:new(n)` reads pad n, `Gamepad:new()` every pad. Left stick: sideways is the analog turn past `pad_dead_zone`, forward / back beyond 0.5 drives. Right stick sideways: STRAFE (modifier) with an analog rate, winning over the left stick. Buttons from `Input.pad_map`, the triggers as `triggerleft` / `triggerright`. `axis_pressed` turns trigger pulls and stick tips into button presses, `MENU_KEYS` maps buttons to menu keys, `MENU_BUTTON` (START) opens the in-game menu, `assign` shares the pads among co-op players. |
| `core/mouse_stick` | `mouse_control`: the pointer's offset from the vehicle on screen as a stick, full deflection at 0.25 window heights divided by `mouse_sensitivity`; dead zone 0.1, drives beyond 0.4. Left button fires, right is STRAFE. Single player only, blocked in the sandbox and while the F2 panel is open. |
| `core/rng` | Seeded per-phase RNG with draw counter. |
| `core/animation` | `AnimClip` from `data/animations.json`, per-instance `AnimState`. |
| `core/assets` | Path resolution and pack check (section 2). |
| `core/audio` | Clip catalog, event table (clip lists, per-vehicle variants, size pitch), callouts and sequences, voice pools, buses, ducking, music (`.ogg`, `.mp3`, `.med`; an `.ogg` / `.mp3` beats a `.med` of the same name). |
| `core/font` | Bitmap fonts from `assets/fonts/`; mask (tinted) or truecolor. `print` `cell` option draws fixed-pitch at each glyph's in-frame x offset. |
| `core/screen` | Fullscreen image fade in / hold / out, with an optional `fx` object animating the picture (`update`, `cue`, `draw`; `cut` skips the fade-in). `is_closing` reports the fade-out. |
| `core/flic` | FLI / FLC player: decodes one frame per `next_frame` into an index buffer and an RGBA `image` (COLOR_256 / 64, DELTA_FLC / FLI, BYTE_RUN, BLACK, COPY); the caller sets the pace. |
| `core/mathx` | `atan2` shim, `heading_deg`. |
| `core/log` | Timestamped, tagged console lines (`info`, `warn`); `recent()` keeps the last 80 for the crash report. |
| `core/version` | Build identity from `build.json` (`version`, `commit`, `dirty`). `string()` for the startup log line; `draw()` puts the build tag in the bottom-right corner of the title, the main menu and the mission select: `OPENSEEK <version>` in the gold CHARS font (`OPENSEEK DEV` without a release tag) and, on a packaged build, the commit under it in grey (`+` when built with uncommitted changes). |
| `game/world` | Stage load, entities, ground colour, collision (`blocked`), objectives, ground dust, `world.time`, `world.rng`, `world.params`. |
| `game/debris` | Explosion shards (`data/debris.json`), owned by the world as `world.debris`: `burst(name, x, y, opts)` throws the named burst, `update` flies the pieces (linear slow-down to rest, sinking through the size rows of their clip, smoke trail puffs, dust puff on landing through `World:add_ground_dust`, then lying on the ground with EXTRA `lying_shards`). Presentation only: fed through the one-way `World:spawn_debris`, random numbers from `math.random`, never read by the simulation. Flying pieces and puffs are drawn by `Renderer:draw_debris`, lying ones in the ground pass over the tread marks. |
| `game/entity` | HP, state machine, damage smoke, hit effects, crater. |
| `game/player` | Movement, collision, altitude, landing, tank turret, fuel, frames, rotors, ammo, death, skins, score, lives. `Player.draw_tank_variant` is shared with the select screen. |
| `game/enemy_heli` | Enemy helicopter posts (leash, respawn), flight AI, fire, death (`world.air_units`). |
| `game/combat` | Weapons, projectiles, firing geometry, hits, AoE, effects, ground enemy AI. |
| `game/enemy_fire` | Enemy firing rules as the original runs them (owned by `game/combat`, `data/enemy_weapons.json`): a gun's routine (volley, burst, reload per fire level), soldiers and their wander, proximity mines, a hangar tank's parked gun, the helicopters' weapon modes, and the homing missiles' bearing refresh with the radar / radio tower penalty. |
| `game/air_strike` | Air strike (owned by `game/combat`): impact schedule drawn from `world.rng` at the call, detonated on `world.time`, damage in toughness units; EXTRA craft, rocket and bomb visuals with their shadows. |
| `game/mission` | Objectives, progress, return to base. `Mission.for_stage(world, players, stage)`. |
| `game/rescue` | People to pick up: buildings holding POWs, the crash-site crews, walkers, flung bodies. |
| `game/saboteur` | Agent drop-off and recovery at the linked buildings. |
| `game/powerups` | Power-ups as the original runs them (`data/powerups.json`, times in ticks of 1/70 s). A dying building's drop is drawn from a 16-entry table built per player at phase start: armor and fuel alternating, then `ammo_share` 10 entries split evenly among the carried weapons that have a pickup frame (chain gun and air strike have none), so ammo only drops for what the player carries; free play carries everything. Every other entry turns to fuel or armor while the nearest player is below `low` (fuel 20 %, armor 5), and below `critical` (10 %, 2) the drop is always that supply, fuel first. Medals only come from forced-drop classes. Lifetime `lifetime` 1220 / 976 / 732 ticks by `pickup_level`, blinking the last `blink` 300, frozen while every player is down. Taken inside a `reach` 16 px box around the vehicle centre, by fly-over unless the difficulty says to land on it (medals, fuel / armor); `F6` forces fly-over for everything. Fuel and armor add half the maximum, ammo its `ammo_pickup` up to `ammo_cap` 999. EXTRA `weapon_finds`: a drop is with `find.chance` a weapon of the vehicle that the player does not carry (its icon alternating with the unused GET / ME frames, over the pulsing `find.glow` halo); taking it adds the weapon to the player's list for the rest of the phase with `find.ammo` 15 % of its starting load (at least one round), rebuilds the table and stamps `Player.found_weapon` / `found_time` for the HUD notice. |
| `game/difficulty` | Difficulty presets over the difficulty Config keys (`data/difficulty.json`): choices, apply, match. |
| `game/renderer` | Ground pass, object pass (y-sorted, culled), player layer by `is_airborne()`, shrapnel overlay. |
| `game/lightfx` | Night light map, additive flashes. |
| `game/postfx` | World-view post-processing and soft shadows (`data/postfx.json`); `enter(world)` picks the stage's mission look; `begin_world(alarm)` takes the view's low armor warning from `game/impact_fx`. |
| `game/impact_fx` | EXTRA hit flash, camera shake and low armor warning (`data/impact_fx.json`), fed by the `World:hit_flash` / `:player_hit` / `:explosion_light` / `:player_death_light` / `:weapon_fired` forwarders and the players after each tick; the shake is a per-camera offset applied in `Camera:apply`, the warning is handed per view to `PostFX:begin_world`. |
| `game/tracks` | EXTRA tank tread marks (`data/tracks.json`): laid from the players after each tick, faded out by age, drawn by the renderer's ground pass as one sprite batch. |
| `game/detail_fx` | EXTRA details (`data/detail_fx.json`): tank recoil and muzzle smoke, chaingun casings, tread dust, wreck smoke, pickup glint (drawn from `Powerups:draw`), target glint (drawn from `Renderer:_draw_entity`). Fed by the `World:weapon_fired` / `:wreck` forwarders and the players after each tick; ground layer drawn in the renderer's ground pass, smoke by `Renderer:draw_detail_air`. |
| `game/sound` | Listeners, panning, attenuation, engine loops, radio queue, situational callouts (section 10). |
| `game/shadow` | Altitude-scaled silhouette shadows, off at night. |
| `game/weather` | Snow (mission 1), rain (mission 2). Presentation, global RNG. |
| `game/vehicles` | Free-play weapon cycles, equip bay and special lists, variants (`data/vehicle_variants.json`, loaded on first use), labels. |
| `game/campaign` | NEW GAME run state: solo run fields or `app.coop_run` (per-player score, lives, threshold, out flag, `Loadout`; lives rule and pool), active players, `advance`, `finish` (out of vehicles), `complete` (last stage cleared: ending, credits, high scores), `resume` (reopen a slot or the autosave at its briefing). `app.run_record` sums each cleared phase over all players (`record_phase`, from the gameplay scenes: phases, simulated time, vehicles lost, stats screen kills, rescues, badges). |
| `game/loadout` | Campaign inventory: levels, bays, special (always one, the vehicle's first by default), ammo multipliers, `buy`. `Loadout.info` (cost, description lines) from `assets/pow/weapon_info.json`; `price` = list cost minus `trade_in` (`data/shop.json`) of the owned level's cost. `Loadout.active(app, player)` picks a co-op player's own. |
| `game/score` | Kill values, phase bonus weights, bonus-life ladder, `Score.award`. |
| `game/stats` | Destruction categories and stage totals. |
| `game/replay` | Replay header, delta input, checksums, `.osr` files; hands each finished recording to the hosting page when the web build ships `build.json` with `replay_upload`. |
| `game/savegame` | Campaign save slots: capture / apply a run (stage, score, lives, bonus ladder, whole inventory, run record; co-op adds a `coop` table per player), one JSON file per slot in `saves/`, plus the `autosave.json` of the run in progress (written by each campaign briefing, removed by `Campaign.finish`). |
| `ui/hud` | Gauges, weapon icon, radar (with per-player auto zoom, home base, pickup and air strike blips), weapon sights (the air strike's rests on its target), counters, OVERKILL banner, weapon find notice, rolling score. |
| `ui/end_stats` | DESTRUCTION STATS screen: lines count up (icons filling), then wind back down as each pays its bonus into TOTAL SCORE; per-player columns in co-op. |
| `ui/crash_fx` | EXTRA crash picture effects (`data/crash_fx.json`), the `fx` of the crash / game-over overlay: smoke, fire glow, embers and heat haze composed at the picture's resolution, flash and static entrance, static burst on a radio cue (`crash_fx`); the typed cause of the loss (`crash_cause`, from `Player.damage_cause`); the run's trivia (`crash_stats`, from `World.tally` and the campaign record via `GameplayBase:crash_stats`). `CrashFX.show` picks the picture and its timing for both gameplay scenes (the fx is nil with every extra off); `CrashFX.preview` is the overview's `Delete` key. |
| `ui/equip_screen` | Equip widgets over `assets/equip/layout.json`. |
| `ui/shop_screen` | Original shop flow over `data/shop.json`: select a level icon (description, trade-in COST), PURCHASE buys it. LOADED on the owned level, lower levels darkened and unselectable, medal purse bottom-left (digits, large medal per 10, small per 1). Arrows move over the grid, Enter purchases, Tab switches vehicle, Esc is DONE. `shop_fx` (EXTRA.md) animates the purse, greys levels the purse cannot pay for (not the selected one, whose COST reads red), slides the focus frame, marks the hovered box and dims LOADED while a higher level is selected. |
| `ui/menu` | Main menu over `MAINP`, `main` font (`mainmen` on a pack exported before `main` existed). Also drives the `new_game` and `advanced_menu` submenus. |
| `ui/player_tag` | Co-op player colours, `PLAYER n` badge for the shop / equip screens. |
| `ui/mission_menu` | Briefing menu, button row, objective icons, `assets/mission_text.json`. |
| `ui/mission_select` | `STAGE0X_MPIC` carousel over the missions present, phase buttons. |
| `ui/data_setup` | First-run screen without a usable pack: runs the converter, restarts into the game (section 2). |
| `ui/error_screen` | `love.errorhandler`: writes `crashes/crash_<date>_<time>.txt` into the save directory (error, traceback, build, LOVE, OS, renderer, window, pack status and edition, the last log lines) and shows the error, the report path and the first traceback lines over the dimmed engine intro card, in the shipped TTF, so it works without the pack. `C` copies the report, `O` opens the folder, `R` (pad A) restarts, Esc (pad B) quits; a tap copies on touch builds. Under `--selftest` it prints and exits with status 1 instead. |
| `ui/info_screen` | CREDITS / HIGH SCORES shell. |
| `ui/pointer` | Mouse / touch pointer in 320x240 design space. |
| `ui/layout` | 320x240 design space, letterbox `fit`. |
| `ui/hint` | Two-tone footer key hints: `{ENTER} LOAD` draws the braced key name gold and the action white. |
| `ui/touch_controls` | Single-player on-screen controls: floating stick (left half), FIRE, STRAFE, LAND, WEAPON, MENU. Held state and analog `turn()` read by `InputSource.Local`, buttons queue edge events. Stick angle from vertical: straight within 8 deg, turn rate linear to full at sideways, drives within 65 deg of up/down, dead zone 0.25 of the radius. Buttons draw their white icon from `content/mobileui/icon_<id>.png` (label when missing), tinted gold or white. MOBILE UI options: `touch_color`, `touch_opacity` (multiplies every alpha), `touch_button_scale`, `touch_stick_scale`, `touch_left_handed` (buttons measured from the left edge, stick on the right half). Drawn while the last input was touch (from the start under `--touch`). |
| `dev/debug_panel` | Entity inspector and type editor, saves `data/entity_types.json`. F2 in gameplay. |
| `dev/selftest` | Scripted phase run three ways, compared per tick. |
| `dev/photo_mode` | `--photo` only: holds the scene, puts a free view (focus offset, zoom multiplier, turn) on the scene's camera for the length of a draw, and captures the scene's `draw_world()` into a canvas of the output size (`data/photo.json`). Presentation only; steps whole ticks through the scene's update. |

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
    `World:blocked` binary-search it and check `mobile` entities (route units,
    hangar tanks, wandering soldiers) separately, in list order.
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

- Entity hit points are the class toughness (`+0x20`, `LEVELS.md`), as in the
  original; the class `hit_points` is only the score value. A folded turret
  takes its own class toughness, enemy helicopters the `badheli` class's. A
  toughness of 0 dies to any hit. Player weapon damage, ammo, cadence and level
  patterns are the original's (`research/WEAPONS.md`, cadence converted at 70
  ticks per second); speeds and ranges are openSEEK's, except the tank's
  flame thrower, whose stream only closes at the original's 140 px/s and
  40 / 120 / 120 px reach per level.
- Tank weapons in every mode are the original's: chain gun, shells, flame
  thrower and air strike in the bays, power shell, ground-to-air and mine as
  specials (`Vehicles.BAY_WEAPONS` / `SPECIAL_WEAPONS`; free play carries all
  of them, `Vehicles.WEAPONS`). The flame thrower (`flame_thrower`) spends one
  of its 300 units per flame, each a `fire` puff that blooms and thins out
  over its flight and deals 1 toughness to the first ground or air target it
  touches; level 3 fires two, from either side of the nozzle. EXTRA
  `flame_momentum`: a flame also keeps the tank's speed along the aim, outside
  its range count, so the reach holds ahead of a driving tank.
- Player armor is the original's scale: max armor `floor((slider + 5) *
  armor_base / 15)`, the slider being the equip armor 0..1 as 0..29 (chopper
  6..45, tank 13..90, 25 / 50 at the default). An armor pickup restores half
  the maximum. Enemy rounds deal their weapon's `enemy_damage` for the damage
  level, times `enemy_damage`.
- `CombatSystem:fire` builds projectiles from a weapon def and level: spread,
  streams, swing (`swing_deg` amplitude), side offsets, `alternate_side`.
  `proj_type "flame"` lays rays of damage patches per level `angles` and lateral
  `offsets`; `bomb_drop` glides, then hits every ground entity within `aoe` px
  on both axes (the original's square blast); `mine` lies where dropped and
  blasts like the bomb after its fuse, or on a fresh fire press with
  `remote_mine` (`CombatSystem:player_mine` / `detonate_mines`, `self_damage`
  to players inside); `air_strike` goes to `game/air_strike` (one pending per
  player; `fire` returns false on a refused call so `fire_for` spends no ammo).
- Weapon flags: `pierce` (power shell) flies on through every target it kills;
  `lock_arc` widens the lock cone (ground-to-air 180, all around); `barrel`
  fires from the tank's live barrel tip (a number names one barrel, the flame
  thrower's nozzle); `flight_anim` plays the sprite clip once over the level's
  `range` instead of on the clock; `momentum` is the share of the shooting
  player's speed along the aim a round keeps (`Player:velocity`, carried as
  `Projectile.carry_vx` / `carry_vy` and not counted into `traveled`; EXTRA
  `flame_momentum`); `ricochet` false drops the ricochet off a
  target that survives; `target_kind` limits hits to `ground`
  or `air`.
- Player range 640 px unless the weapon or its level sets `range`.
- Projectiles carry `owner`. Homing steers at capped `turn_rate`.
- Player ammo: `seed_ammo`, `has_ammo`, `consume_ammo`, `add_ammo`; gated in
  `GameplayBase:fire_for`. All spawning goes through `combat:fire`.
- Weapons flagged `shadow` cast shadows only with soft shadows on: `true` from
  full flying height, a number from that share of it (shells and rounds fired
  along the ground, 0.35). A falling bomb closes in on its shadow.

Ground combatants: any type with `armed` and `detection_radius > 0`. Enemy
fire follows the original (`game/enemy_fire`, `data/enemy_weapons.json`, times
there in ticks of 1/70 s, three values = EASY / MEDIUM / HARD picked by
`enemy_fire_level`):

| Kind | Fires | Detect | Attack | Moves |
|------|-------|-------:|-------:|-------|
| flak_turret | its class `behaviour` = one of 20 firing routines | 300 | 270 | no |
| tank | the routine of its folded turret class | 300 | 270 | hull `behaviour`: 0 / 3 a route at 35 px/s, 1 / 2 a hangar ride |
| soldier, soldier_aggressive | `behaviour` 0 / 3 a bullet, 1 a homing missile | 300 | - | `behaviour` 3 wanders |
| mine (soldier class, `behaviour` 2) | proximity charge | - | - | no |
| truck | unarmed | - | - | routes at 35 px/s |

- A unit acts on the nearest live player inside `detection_radius` (the
  original runs a unit while it is on screen, which the simulation may not
  read).
- Guns turn at the routine's `turn` (98.4 deg/s, routines 15 and 17 twice
  that) and fire only inside `attack_range` once the aim error has stayed
  under its `arc` (2.8 deg, routine 15: 22.5) for `settle` 30 ticks.
- A routine is `shots` (weapon, `forward` / `side` muzzle offset in px, a
  `side` list alternating per volley, `angle` off the barrel, `every` for a
  side round fired each time the reload passes that many ticks, `reloading`
  to fire it only between volleys, `volley` within a `cycle`), `reload`
  (+ `reload_random`), and `burst` volleys closed by a `pause`. Burst guns
  speed up with the fire level; missile and shell guns do not.
- Rounds are the `enemy_*` weapons of `data/weapons.json`, one per original
  projectile type: `enemy_homing` / `enemy_heli_homing` (280 px/s, turn 98.4
  deg/s toward a bearing refreshed every 9 / 7 / 5 ticks), `enemy_missile`
  (straight), `enemy_bullet` (140 px/s), `enemy_tracer` / `enemy_tracer_fast`
  (accelerating), `enemy_shell` (280 slowing to 140, bursts after 64 ticks),
  `enemy_round` and `enemy_flak` (140 px/s, sprite of the stage's projectile
  class `proj_class`; flak has a wide `proj_radius` and a random lifetime).
- `World.homing_jam`: each destroyed radar (class flag 0x10) adds `penalty` 2
  ticks to the ground missiles' bearing refresh for the rest of the phase,
  each radio tower (0x20) to the helicopters' missiles.
- Soldiers snap round (`turn` 787 deg/s), fire when facing the player, reload
  64 + rand(0..255) ticks.
- Mines arm when a player comes within `trigger` 100 px, blow after `fuse`
  and take `damage` 1 / 2 / 4 if a player is still that close.
- `enemy_fire_rate` and `enemy_aggression` are extra scales on every reload
  and on both radii, 1.0 in every preset.
- Structures take their power-up drop and explosion from the exported class
  fields (`drop`, `behaviour`, `is_target`), as the original: no drop
  entry never drops, behaviour 1 always drops a medal, the rest drop a random
  pickup 7 times in 8. Destroy targets and forced-drop classes get the ring
  blast (`medium`, RDNEXP), classes with a drop entry the small one (`small`,
  EXPLO32), the rest the fire puff (`fire`); in the data that follows the size
  of the building (`research/LEVELS.md`, "Effect spawner"). Stage exports
  without the fields fall back to the kind's `explosion` and the size rule
  (large buildings drop 7 in 8).
- Explosion clips play at the original's rates (`data/animations.json`: 17.5
  fps, the fire puff and the dust puff 35 and 17.5, the flak burst 9.84);
  mines, helicopters and bombs are `large` (EXPLO64) as there. A clip's
  `missions` table names the clip drawn instead in
  a mission (`World:explosion_clip`): the ring blast is RDNEXPS / RDNEXPJ /
  RDNEXPR in missions 1 / 2 / 4, when the pack has them. The size also keys
  the explosion light (`game/lightfx`), the shake (`data/impact_fx.json`), the
  wreck smoke (`data/detail_fx.json`) and the `explosion.<size>` sound.
- Armed units keep openSEEK's larger blasts instead of the original's
  EXPLO32: flak turrets and tank turrets the ring blast, tank hulls EXPLO64
  (`data/entity_types.json`).
- Shards follow the original's spawners (`game/debris`, `data/debris.json`):
  a destroyed tank hull, tank turret, flak turret or building
  throws the `wreck` burst (four iron pieces, eight METAL8 bits; `building`,
  with half as many again, off a building large enough for a crater), a
  fire-puff prop `scrap` (two bits), a bomb, a mine, an enemy mine or a
  crashed helicopter `blast`
  (a cross of four METALRT plates, four METALSZ chunks on the diagonals,
  eight bits), an air strike round the weapon's `debris` burst, an FFR hit
  `ffr` sparks along its flight. Iron pieces and chunks shrink through their
  three size rows as they sink and land in the mission's dust puff; one iron
  piece in four and every chunk trails `missile_smoke`. A destroyed player
  vehicle throws the larger `player` burst (the original throws the blast's
  shards there). EXTRA `shard_amount` scales the counts of every part not
  marked `fixed`; `max` caps the flying pieces. EXTRA `lying_shards`: a landed
  piece of a kind with `lie` stays on the ground for that many seconds,
  fading over `lie_fade`, the oldest removed past `max_lying`.
- `data/overrides.json` fixes single sprites where the data is wrong or
  missing: `assets` (sprite file -> fields, every stage) and `stages` (stage
  -> sprite file -> fields); a stage entry wins field by field. Fields:
  `explosion`, `drop` (pickup kind, `true` random, `false` none).
- Two-part units (tank + `*tanktop` / `tankt2`, radar + dish) fold at load
  (`TURRET_DEFS`). Turret absorbs damage and dies first; its hit points are
  its own class toughness.
- Unit movement follows the original (`movement` in `data/enemy_weapons.json`,
  keyed by kind and class `behaviour`; ticks and px per tick):
  - Route units (tanks, trucks) ease between waypoints at `patrol_speed` 35 px/s,
    turning `patrol_turn` 98.4 deg/s, and keep driving while they fire
    (`Entity:_patrol`). A route loops unless the mode says `once`: stage41's
    convoy trucks (4) and their escort tanks (3) stop at the last waypoint, and
    the first to arrive stops everyone on that route. `pause` / `pause_at`: the
    patrol jeep (1) waits 183 ticks at its 8th waypoint and at the last.
  - `yields` (tank 0 / 3, truck 4; `CombatSystem:_update_routes`): a unit stops
    while a player on the ground is within `yield` 100 px on both axes, and with
    it everyone on its route. The stop only lifts while the nearest player is
    airborne (the original's rule: a tank that came this close holds the route
    up for good).
  - Hangar tanks (tank 1: stage12 `shut.bin`, west; 2: stage21 `jhanger.bin`,
    south; `World:_link_hangar_tanks`, `CombatSystem:_update_hangar`): the hull
    slides `ride.ticks` 40 out of its hut and back without turning. It rides out
    once a player has it within `ride.cone` 45 deg of the vehicle's heading or
    is closer than `ride.near` 100 px, and back in once neither holds; a ride
    runs to its end. Less than half way out the gun is parked at `ride.park` 270
    and silent. Right inside, a standing hut shields the tank; it is drawn under
    the hut.
  - Wandering soldiers (`soldier.wander`, behaviour 3, stage43): legs of 180
    ticks. 80 walking at 0.5 px per tick to a random spot within `reach` 31 px
    of the post, 40 turning on the player, 60 firing the way they then face.
- Trucks and jeeps (kind 10) are unarmed, hittable (`truck` in
  `data/entity_types.json`) and blow up `small` without shards; a class of
  toughness 0 dies to any hit. Stage41's four destroy targets are trucks.

Enemy helicopters (`enemy_heli.lua`): one per `badheli` entity, its post. A
heli starts on its post; further than the class leash (`field_2e`, 300..5000
px) from it on either axis it turns home. Shot down, it returns after the
class respawn delay (`field_2c`, 600..1800 ticks; negative never) at a random
point more than `respawn_clear` 500 px from every player. `SPEED` 110, `TURN_RATE`
120, `ORBIT_R` 270, hit points from the `badheli` class toughness (`MAX_HP` 20 without one), `BLAST_RADIUS`
70, `BLAST_DAMAGE` 2 / 3 / 4 by damage level, `REACTION_DELAY` 0.9, `FRONT_LIMIT` 90, `FIRE_FRONT` 115.
Weapon from the marker's class `behaviour` (`helicopter.modes` in
`data/enemy_weapons.json`): 0 and 1 a homing missile every 30 + rand(0..63)
ticks, 2 a bullet every 31; 1 also turns twice as fast. Fires inside `range`
300 with the nose within `fire_cone` 11.25 deg. Approaches beyond
`ORBIT_R * 1.25`, otherwise orbits within `FRONT_LIMIT` of the player's facing.

## 8. Missions

- Each `assets/stageMP.json` has a decoded `objectives` block (`destroy`,
  `rescue`, `special_end`, `target_classes`, `n_target_entities`). The phase's
  goals come from the stage data, as the original counts them at load
  (`research/LEVELS.md`, "Phase objectives"): every `is_target` entity
  destroyed, everybody on the stage picked up, every agent back aboard.
- `data/missions.json` names them per stage (labels, or a narrower `destroy`
  match); a stage without an entry gets the three above. After all objectives
  the player lands on the base pad (`basecirc.bin`, or `h.bin` in missions 0
  and 3, or `home_base_asset`): on the ground inside a box of `home_radius`
  (24 px, 48 for a team) around it.

```jsonc
{
  "stage01": {
    "briefing": "short in-game line",
    "vehicle": "tank",              // optional, locks shop and equip in a solo campaign
    "home_radius": 24,              // optional
    "home_base_asset": "lh.bin",    // optional
    "objectives": [
      { "type": "destroy", "target": "radar.bin", "count": "all" },
      { "type": "destroy", "kind": "structure", "min_size": 28, "count": 5, "label": "..." },
      { "type": "destroy_targets" },                 // every is_target entity
      { "type": "rescue_people", "optional": true }, // RescueSystem; optional defaults to the stage flag
      { "type": "sabotage" },                        // SaboteurSystem
      { "type": "rescue", "target": "pow.bin", "radius": 40, "count": 4 }
    ]
  }
}
```

- Match fields: `target` (asset filename), `kind`, `min_size`; `optional: true`
  does not gate the win.
- People (`game/rescue`). A building holds the number its class names (`pows`:
  stage00 1 + 1, stage01 3 + 3, stage12 3 + 3, stage31 2 + 2 + 2) and belongs to
  the pickup pad whose class links it (`parent_class`, an entity index; pad
  `behaviour` 1). A vehicle on the ground within 24 px of the pad calls them
  out one at a time (the next after 120 ticks, or at once when one boards or
  dies); they walk at 35 px/s and board within 16 px. If the vehicle leaves
  they walk back in. They start and end at the building's middle and are
  drawn in the ground slot below the solid objects (both gameplay scenes), so
  the roof hides them: they come out of the building and go back into it.
  The building cannot be damaged until the last one is aboard or dead; its
  `powhere.bin` flag and its pad show only while somebody is inside. The
  stage22 crews (kind 11) stand by their wreck and run over once a vehicle is
  down within 50 px of it.
- With `enemy_hunts_people` every gun within 200 px of a person stepping into
  the open (out of a building, or an agent out of the vehicle) turns on them
  until they are aboard, inside or dead (`CombatSystem:person_out`,
  `Entity.person_target`), with no range limit. An enemy round kills only the
  person it was fired at; the player's rounds kill people only with
  `friendly_fire_pows`. The body is thrown clear, spinning, for 42 ticks.
  People aboard die with the vehicle. The objective is done when nobody is left
  to pick up; where the stage flags the rescue as the objective (`rescue`,
  not stage12) the phase fails once all of them are dead.
- Sprite: every person is the stage's class 20, `newdude.bin` in missions 0 and
  3, `pow.bin` in the others, exported per mission palette as clips
  `newdude0`, `pow1`, `pow2`, `newdude3`, `pow4` and `<clip>_dead`
  (`World:walker_clip`).
- Objectives show white on the radar until completed (destroyed, emptied or
  collected). The player's base shows black, as in the original: its buildings
  as normal blips and the home pad (`World.home_entity`) as a larger one
  (`base_size` in `data/hud.json`).
- Base buildings (class flag `0x40`, `Entity.base_building`) cannot be damaged
  by the player, as in the original; with `friendly_fire_pows` on they can be
  destroyed but give no score, streak, stats or power-up drop. Those with no
  class toughness (`base1.bin`) get `base_hit_points` from the `structure`
  entry of `data/entity_types.json`.
- Agents (`game/saboteur`, stages 11, 13, 32). A drop pad (pad `behaviour` 0)
  belongs to the building its class links, which weapons cannot damage. A
  vehicle on the ground at the pad sends an agent in. It comes out after 60
  ticks, or on stage13 (stage global 5 = 65535) when every building has its
  agent inside, walks back to the pad and boards a vehicle that lands there
  again; like the POWs it goes in and out under the roof. A building its
  agent has left loses 2 toughness a tick and blows up
  at 0 (stage11 tents 150 ticks, stage13 tents 3); class `behaviour` 5, the
  stage32 wrecks, never does. The objective is every agent back aboard; an
  agent killed fails the phase. Agents do not count as rescued.
- A failed phase (`Mission.state == "phase_failed"`, `fail_lines`) shows
  ALLIES EXTERMINATED or OBJECTIVE IMPOSSIBLE, PHASE FAILED for 3 s, costs a
  vehicle and starts over (`on_phase_failed` in the gameplay scenes); out of
  vehicles it is game over. Co-op spends one per player, or one of a shared
  pool.
- Tank-only phases (`"vehicle": "tank"`: stage11, stage23, stage32, where the
  briefing grounds the chopper) lock the shop and equip screens to the tank in
  a solo campaign only (`Campaign.required_vehicle`). A single mission, free
  play and co-op keep the choice.
- `special_end` (stage43): the commander building (target of class `behaviour`
  2) is out of the world (`Entity.dormant`) until it is the only target left,
  then appears with the standing order DESTROY THE COMMANDERS BUILDING
  (`Mission.notice`). Destroying it wins the phase with no flight home.

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
| Tank | GREEN, DESERT, ARCTIC, JUNGLE, DESERT 2 | Player `TANKBGRN` / `TANKTOP`; enemy hull + turret pairs from stage01 (`tank` / `tanktop`), stage11 (`stank`), stage21 (`jtank`). DESERT 2 is the mission 3 night tank (desert hull + `TANKT2`), its turret re-rendered in the mission 0 day palette as `player/vtank_desert2_top_f0.png` (`export_player.py`); the enemy night tank keeps its own art. |

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
  min/max distance, max_voices, priority, group over `defaults`. `clips` picks
  one clip at random per play; `<event>.<vehicle>` is a per-vehicle variant
  (the tank's own `voice.phase_start`). `weapon.<name>` and
  `explosion.<size>` are derived. Unmapped events are silent.
- The mapping follows the original's own use of each file: fire sounds per
  weapon, `kzexp` for every explosion (`size_pitch` sets sizes apart, EXTRA
  `explosion_pitch`), `holexp` for the enemy cannon, `rico1` / `rico2` on a
  damaged enemy, `weapon1..6` / `*.spc` as the weapon announcements on
  selection. Not in the original: `missionc`, `powcomeo`, `powletsg`, `yea`
  (objective cleared) and the player hit ricochet.
- Callouts (`game/sound`, thresholds in `callouts`): phase start ("cleared" /
  the tank's start line) on every spawn, weapon announcements (skipped within
  `select_guard` of the last selection, a newer one replaces the older),
  `reload` on an empty trigger (once per weapon), armor below half and critical
  (once, re-armed by a repair), the `warn` beep every `warn_period` while fuel
  or armor is critical, touchdown on the home pad, "just in time" on a critical
  pickup, "finish him" when a hit takes an enemy helicopter below `finish_him`,
  and `follow_ups` (return to base, then "let's go"). Fed through `World`
  forwarders and the players after each tick.
- Screens: the crash / game-over picture plays the `crash` sequence (radio
  "come in" by vehicle, `noisesir`, `comein2b`; a dismissed picture plays no
  more; with `crash_fx` the noise also shows as static, `ui/crash_fx`); the stats screen plays `icons` per kill icon and `click` per tally step.
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
- Music: `.ogg` / `.mp3` / `.med` in `assets/music/`, as the original uses its
  three modules: `menu` from boot (title), on the main menu and on every
  briefing (after each phase); per phase the first of `stage<MP>`,
  `mission<M>`, `game`, else silence (the original plays none in play or the
  overview); `ending` for the ending and the credits after it; `hiscores` on
  the high scores after a run (`menu` when browsed from the menu). The pack
  holds `menu.med`, `hiscores.med` and `ending.med` (OctaMED, played through
  ModPlug); an `.ogg` / `.mp3` of the same name replaces one.

## 11. Additions beyond the original

Toggleable extras (EXTRAS page):

| Key | Default | Effect |
|-----|---------|--------|
| `explosive_trees` | on | Tank at speed destroys trees for a small armor cost. |
| `tree_crush_speed` | 0.7 | Fraction of top speed required. |
| `hit_flash` | off | Damaged armed enemies flash white (`game/impact_fx`). |
| `camera_shake`, `camera_shake_amount` | off, 1.0 | Explosions and hits near the camera shake the view, scaled by the amount (`game/impact_fx`). |
| `low_armor_fx`, `damage_flash` | off | Low armor pulses the view's edges red and drains its colour; each hit taken flashes the edges (`game/impact_fx`, drawn by `game/postfx`, needs POST FX on). |
| `pickup_glint` | off | A light sweep runs across each pickup now and then (`game/detail_fx`). |
| `target_glint` | off | The same sweep, warm tinted, across every live mission objective (`game/detail_fx`, `game/renderer`). |
| `air_strike_fx` | on | Air strike sight on a pending target, radar blip, friendly craft with their rockets and bombs (`game/air_strike`, `ui/hud`). |
| `remote_mine` | on | The tank's mine waits for a fresh fire press and its blast also hits players inside it; off, the original's 1.4 s fuse that spares the player. Replay parameter. |
| `shard_amount` | 1.5 | Multiplier on the pieces an explosion throws; 1.0 is the original's count (`game/debris`). Presentation only. |
| `lying_shards` | on | Landed shards stay on the ground for a few seconds and fade, instead of vanishing in their dust puff (`game/debris`, `lie` in `data/debris.json`). Presentation only. |
| `flame_momentum` | on | Flame thrower flames keep the tank's speed along the aim, so the stream holds its reach while driving; off, the original's fixed 140 px/s. Replay parameter. |
| `weapon_finds` | on | A drop is now and then a weapon the vehicle does not carry, lying in a gold halo; taking it adds the weapon for the rest of the phase and the HUD names it (`game/powerups`, `ui/hud`). Off, drops are only ammo for carried weapons, as the original. Replay parameter. |
| `explosion_pitch` | on | The one explosion sound pitched by blast size (`core/audio`, `size_pitch`). |
| `ending_stats` | on | The run record typed under the ending's FIN01..03 story (`scenes/ending`, `data/ending.json` `stats`). |
| `crash_fx`, `crash_cause`, `crash_stats` | off | The crash / game-over picture animated (smoke, fire, embers, heat haze, flash and static cut); the cause of the loss typed at its foot; the run's trivia (one line before a respawn, a centred panel on game over). Any of them holds the picture before a respawn long enough to read, with the simulation held under it (`ui/crash_fx`). |
| `tank_tracks` | on | A driving tank leaves faint tread marks that fade out (`game/tracks`). |
| `tank_recoil`, `shell_casings`, `tread_dust`, `wreck_smoke`, `shell_impact` | on | Turret kick and muzzle smoke on a shell shot, chaingun casings, dust behind a fast tank, smoking wrecks, an explosion where a tank shell strikes (`game/detail_fx`). |

Options:

| Keys | Page | Effect |
|------|------|--------|
| `night_lighting`, `night_brightness` | VIDEO | Night ambient, headlight cone, explosion and muzzle lights. |
| `effects_flashes`, `flash_intensity` | VIDEO | Additive flashes and screen washes. |
| `postfx_enabled`, `postfx_preset`, `postfx_grade`, `postfx_contrast`, `postfx_sharpen`, `postfx_bloom`, `postfx_vignette`, `postfx_grain`, `postfx_soft_shadows` | EFFECTS | World-view shader (HUD excluded). Presets NONE / MILD / FULL; soft shadows add rotor, smoke and projectile shadows. |
| `speed_scale` | GAMEPLAY | Motion multiplier; animation unscaled. |
| `hud_scale` | GAMEPLAY | HUD size and inset. |
| `axis_aligned_pickups` | GAMEPLAY | Screen-upright pickups and pads, as the original. |
| `friendly_fire_pows` | GAMEPLAY | Player rounds kill POWs and saboteurs and can destroy the player's base buildings (no score, stats or drops). |
| `score_count_up` | GAMEPLAY | HUD score rolls to new total (frame time, presentation). |
| `shop_fx` | GAMEPLAY | Animated shop medal purse, unaffordable levels greyed with a red COST, sliding focus frame, hover frame, dimmed LOADED under a higher selection (presentation). |
| `difficulty`, `enemy_damage_level`, `enemy_damage`, `enemy_fire_level`, `enemy_fire_rate`, `enemy_aggression`, `pickup_level`, `land_for_medals`, `land_for_supplies` | DIFFICULTY | The original's EASY / MEDIUM / HARD (`game/difficulty`, `data/difficulty.json`), each value also editable (preset then reads CUSTOM); a named preset is re-applied at startup. `enemy_damage_level` (ENEMY DAMAGE) picks the original's per-weapon enemy damage (`enemy_damage` tables in `data/weapons.json`, `Difficulty.damage_level`), `enemy_fire_level` (ENEMY FIRE) its enemy reloads, burst pauses and missile tracking (`data/enemy_weapons.json`, `Difficulty.fire_level`). Extra multipliers, 1.0 in every preset: that damage (DAMAGE SCALE), the enemy fire rate (FIRE SCALE), and aggression (detection and attack range). `pickup_level` (PICKUP TIME: LONG / MEDIUM / SHORT) is how long a power-up lies (17.4 / 13.9 / 10.5 s). MEDIUM needs a landing to collect medals, HARD also fuel and armor. Replay parameters; replays from before them apply HARD with no landing rules (`Replay.LEGACY_PARAMS`). |
| `enemy_hunts_people` | DIFFICULTY | On (the original): guns near a POW or an agent stepping into the open turn on them. Off: the enemy cannot harm people on foot. Outside the presets. |
| `chopper_skin`, `tank_skin` | GAMEPLAY | Solo chopper and tank variants (section 9a); also set by the vehicle select screen and the overview `V` cycle. Recorded in the replay header. |
| `coop_lives` | GAMEPLAY | Co-op campaign lives: `separate` or `shared` pool (section 9). |
| `master_volume`, `sfx_volume`, `engine_volume`, `voice_volume`, `ui_volume`, `music_volume` | AUDIO | Master and bus volumes. |
| `audio_positional` | AUDIO | Directional mix; off centres all sounds. |
| `coop_split_pan` | AUDIO | Split-screen stereo bias. |
| `voice_callouts` | AUDIO | Radio callouts. |
| `fullscreen`, `vsync`, `window_size`, `show_fps` | DISPLAY | Window mode, letterboxing. `show_fps` draws the counter in the `chars` font on the HUD's pixel grid, under the score readout. |
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
| `data/weapons.json` | Player and enemy weapons: `proj_sprite` (a list picks the first clip the pack has), `enemy_damage` (EASY / MEDIUM / HARD damage to the player when an enemy fires it), levels (`damage` in toughness units, `fire_rate`, `swing_deg`, `range`, flame `angles` / `offsets`), `short`, `icon`, `ammo_max`, `ammo_pickup`, `alternate_side`, `trail`, flame params, `range`, `shadow` (`true` or a share of the flying height), optional `name` (HUD notice; default the key in capitals), `proj_color_missions` (bullet color per mission digit); `air_strike`: target distance, radius, delay, incoming call, marker blink, per level pattern (`strike`, impacts or craft / rounds / lanes, window, impact radius and toughness damage, explosion) and craft visuals. |
| `data/entity_types.json` | Per kind: hit radius, explosion, `armed`, detection / attack radius, `solid`, `collision_radius`, sprite fallbacks, `dead_frame_offset`, `turret_explosion`, `patrol_speed`, `patrol_turn`, `debris`. Flat scalars only (the type editor rewrites it). |
| `data/overrides.json` | Per-sprite fixes over the stage data: `assets` (every stage) and `stages` (one stage), fields `explosion`, `drop`. Empty at present. |
| `data/enemy_weapons.json` | Enemy fire in the original's units (`tick_rate` 70): `turret` (settle, turn, arc), `homing` (bearing refresh per level, radar penalty), the 20 `routines`, `soldier` (with `wander`), `mine`, `helicopter` (with the respawn clearance), and `movement` (route modes, hangar rides, yield distance). Read once by `World` (`world.enemy_rules`). |
| `data/missions.json` | Section 9. |
| `data/vehicles/*.json` | Vehicle tuning (sandbox editable); `armor_base` is the original's per-vehicle armor factor (chopper 20, tank 40). |
| `data/vehicle_variants.json` | Chopper and tank variants (section 9a). |
| `data/credits.json` | Credits: `styles` (fonts, name offset, label colour) and positioned `entries` (`heading` / `name`, or a label `text`), 320x240 design space. |
| `data/ending.json` | Ending timing (`char_time`, `tab_pause`, `hold`, fades, text `cell`), music track, `anim` (`frame_time`, `cues`: event -> frame list, `loops`: event, level, fade start and length in frames), `stats` (position, line height, columns, keys per picture, labels) and `preview` (the record and score F11 shows outside a run). |
| `data/animations.json` | Named animation clips. |
| `data/hud.json` | HUD layout; sprite paths through `core/assets`. The `notice` item is the weapon find line: `text` format, `font`, `time`, `fade_in`, `fade_out`. |
| `data/audio.json` | Sound events (`defaults`, `events` with clip or `clips`, per-vehicle variants, `size_pitch`, `group`), `callouts` (armor / fuel thresholds, warning period, selection guard, finish-him mark, follow-up lines) and `sequences` (timed screen cues). |
| `data/photo.json` | Photo mode (`--photo`): `outputs` (label, `w`, `h`; an entry without a size is the window), zoom limits and wheel step, turn step (degrees) and drag rate (degrees per pixel), slow motion speed. |
| `data/postfx.json` | `look` (100% values), `missions` (per mission digit, look fields that differ, e.g. the cold grade of mission 1) and `presets`. |
| `data/difficulty.json` | EASY / MEDIUM / HARD presets: values for each difficulty key. |
| `data/impact_fx.json` | Hit flash time / strength; camera shake per explosion size, per fired weapon (`fire`, the tank `shells`), player hit and player death (amount in world units, time, radius); `low_armor` (armor threshold, floor, fade, edge color and strength, pulse share and rate range, desaturation, edge radii, hit flash time and strength). |
| `data/powerups.json` | Power-ups in the original's units (`tick_rate` 70): `lifetime` per pickup level, `blink`, `reach`, `medal_flip`, the drop table (`table_size`, `ammo_share`, `low` / `critical` fuel fraction and armor), `fuel_gain`, `armor_gain`, `ammo_cap`, PICKUPS `frames` and `ammo_frames` per weapon, `find` (chance, ammo share, call-out frames and `glow` halo of a weapon find: color, size in art pixels, alpha, pulse depth and rate). |
| `data/debris.json` | Explosion shards: `kinds` (clips, `frames` per tumble, `sizes` rows, `variants`, `speed` and `rest` time, `height` and `fall` or `life` and `fade`, `spin`, `reverse` share, `trail`, `dust`, `cone`), `bursts` (parts of `kind` and `count`, `ring` angle and `jitter` for an even spread, `fixed` to ignore `shard_amount`), `lie` seconds on the ground per kind with `lie_fade`, `lie_tint` and `max_lying`, `max` flying pieces. |
| `data/detail_fx.json` | `recoil` (weapons, kick, time, muzzle smoke), `casings` (weapons, color, size, speed, drag, lifetime), `tread_dust` (speed threshold, interval, puff size and lifetime, color per mission digit), `wreck_smoke` (time and interval per explosion size, wind, tint, thinning), `pickup_glint` and `target_glint` (period, sweep time, band width, strength, screen angle, optional `color`). |
| `data/crash_fx.json` | Crash picture effects: `entrance` (flash, static time), `glitch` (cue events and burst time, tear, band, static mix, scanlines, rate), `haze` (amplitude, wavelength, speed), `smoke` (cap, prewarm, fade-in), `cause` (font, delay, pace, position, verbs, labels, lines), `stats` (order, labels, optional rows, the game-over `panel` layout), `respawn` (hold and fade-out of the picture before a respawn), `preview` (the overview preview's cause), and per picture `smoke` emitters, `fire` glows with embers and `haze` ellipses, all in art pixels. |
| `data/tracks.json` | Tank tread marks: lifetime and fade (s), alpha, color, spacing and mark length (world units), gauge and tread width (fractions of hull width), mark cap. |
| `data/shop.json` | Shop `trade_in` share and screen layout: backdrops, box grid, category placement per vehicle, button / COST / purse / description positions, sprite offsets, darkened level tile per weapon level (`powwgads` chopper, `powgadst` tank); `fx` timings, the unaffordable grey and COST tint, LOADED dim, hover alpha and focus slide time for `shop_fx`. |
| `data/settings.json`, `data/keybinds.json`, `data/highscores.json` | Defaults; written to the save directory. |
| `saves/save-<timestamp>-<n>.json` | One campaign save slot each, written to the save directory only (`game/savegame.lua`). |
| `autosave.json` | The campaign run in progress at its last briefing, for the main menu's RESUME; written to the save directory only, removed when the run ends (`game/savegame.lua`). |
| `assets/stageMP.json`, `assets/stageMP/*.png` | Stages; one frame-0 PNG per class, `render` offsets, `objectives`, `is_target`, class fields (`toughness`, `height`, `behaviour`, `drop`, `pows`, ...). |
| `assets/sounds.json`, `assets/sounds/*.wav` | Clip catalog (categories of `{name, file, label, rate}`), mono 8-bit WAV. |
| `assets/mission_text.json` | `stage<M><P>` -> `paragraphs`. |
| `assets/ending/ending.json`, `assets/ending/reganim.flc` | Ending: `prompt` and `slides` (`picture`, `lines` of `{text, x, y}` with tabs, VIC3 `alternate_lines`, `prompt` position); the CD's animation. Registered release only. |
| `assets/music/{menu,hiscores,ending}.med` | The original's OctaMED modules (`SEEKMOD`, `SEEKHMOD`, `SEEKEMOD`). |
| `assets/fonts/<name>.{png,json}` | Atlas + glyph metrics, `charmap` or `word`, `mode` `mask` / `truecolor`. |
| `assets/equip/`, `assets/phend/` | Screen art + `layout.json` rects. |
| `assets/pow/weapon_info.json` | Shop catalogue: vehicle -> weapon -> per level `{cost, lines}` (upper-cased description), from `WINF.BIN` / `WINFT.BIN`. |
| `assets/{credits,hiscore,pow,phase,mission,mainmen,hud,effects,player,fullscreen}/` | Per-screen sprites. |

## 13. Tools

The pack pipeline needs only Python 3.8+ and its standard library
(`tools/image.py` replaces Pillow). Each exporter takes `--game-dir` (an
extracted game: `data/`, `STAGE0N/`, `SFX/`) and writes under
`gamedata.ASSETS`.

`build_pack.py SOURCE --out DIR` (or `--download --out DIR`) is the entry
point:

- `SOURCE` is a game directory (`DATA.JAM` + `DATA.JAL`, or the files
  `UNPACK.EXE` extracted) or a release zip. `--download` fetches the shareware
  `seeksw1.zip` (md5 `0bf3fa0359bbc3186d6041f1cab8b524`) from `MIRRORS` into
  `--cache`.
- `unjam.py` reads the JAM in memory (AR002, `-lh5-`); the game trees are
  normalized into a temporary directory (`data/` lowercase, the rest
  uppercase) along with the top-level `SEEK.EXE` and `REGANIM.FLC` when present;
  every exporter runs in-process; the result replaces `DIR` via
  `DIR.new`; exporter output goes to `DIR.log`. `DIR` must be absent, empty or a
  previous pack (`--force` otherwise).
- stdout: `source ...`, `found N files, EDITION, missions [...]`,
  `download NN%`, `[i/n] export_x`, then `WARN ...`, `ERROR ...` (exit 1) or
  `DONE DIR`.

`build_setup.py` packages the converter: `build/openseek-setup.pyz` (zipapp)
and, with `--pyinstaller`, a one-file executable for a platform without Python
(built on that platform; on macOS for both architectures, which needs a
universal Python). Both bundle `data/entity_types.json` and
`content/fonts/main_synth/`, read through `gamedata.read_resource`.

`build_release.py` builds the downloads into `build/`: `openseek.love` (the
files git lists under `main.lua`, `conf.lua`, `engine`, `lib`, `data`,
`content`, plus `build.json`), the converter zipapp and, with `--windows`,
`openseek-<id>-win64.zip`, with `--macos SETUP` `openseek-<id>-macos.zip`.
`build.json` is the version stamp: `commit` (short
hash), `dirty` (uncommitted changes under those paths) and `version`, the git
tag on `HEAD` when there is one; `<id>` is the tag, else the commit. The tag
format is free. `--love PATH` writes the `.love` alone.

The Windows zip is built without a Windows machine, from two official
downloads fetched once into `build/cache` and checked against pinned SHA-256
hashes:

| In the zip | From |
|------------|------|
| `openseek.exe` | `love.exe` of `love-11.5-win64.zip` with the game icon, then `openseek.love` appended |
| `*.dll`, `LOVE-LICENSE.txt` | `love-11.5-win64.zip` |
| `openseek-setup.pyz` | `build_setup.py` |
| `python/` | `python-3.12.7-embed-amd64.zip`, unchanged; runs the converter |
| `LICENSE.txt`, `README.md` | the repo |

The exe icon: `love.exe` holds the six bitmaps of its `love.ico` verbatim
(256, 128, 64, 48, 32 and 16 pixels, 32-bit uncompressed). Each is overwritten
in place with `content/icon/openseek.png` scaled to that size (area average),
so the file keeps its layout and no resource table is rewritten. The build
stops if a bitmap is not found exactly once.

The macOS zip holds `openSEEK.app`, built from the pinned
`love-11.5-macos.zip` (universal, x86_64 and arm64) and one file made on a
Mac: `SETUP`, the converter binary of `build_setup.py --pyinstaller`, since a
stock Mac has no Python. Nothing is signed; LOVE's `love.app` is not either,
so changing it breaks no seal.

| In `openSEEK.app/Contents` | From |
|----------------------------|------|
| `MacOS/openseek` | `MacOS/love`, renamed |
| `Frameworks/`, `PkgInfo` | `love-11.5-macos.zip`, unchanged (the frameworks keep their symlinks) |
| `Info.plist` | LOVE's with the game's name, identifier (`net.genserek.openseek`), executable, icon and version, plus `NSMicrophoneUsageDescription`; the document types and the exported `.love` type removed |
| `Resources/openseek.love` | the game; LOVE runs a `.love` found there, fused |
| `Resources/openseek-setup` | `SETUP` |
| `Resources/openseek.icns` | PNG entries of 1024 to 32 pixels, each scaled from the one above, the first being `content/icon/openseek_1024.png` |
| `Resources/LOVE-LICENSE.txt` | LOVE's `license.txt` |
| `Resources/LICENSE.txt`, `Resources/README.md` | the repo |

The converter is inside the bundle because macOS runs a downloaded app from a
read-only copy of the bundle alone, where nothing next to the `.app` exists.
`conf.lua` sets no window icon in the fused app: it would replace the Dock
icon with one 256 pixel image. macOS asks for the microphone when an unsigned
app opens the sound output, before the first window; the plist carries the
text of that prompt (`MACOS_MICROPHONE`), since the game records nothing.

Every text file of a pack is written with LF line endings, so a pack is the
same bytes on every platform.

| Tool | Output |
|------|--------|
| `export_love2d.py all` | `assets/stageMP.json`, `assets/stageMP/` for the missions present (`CLEAR_INDICES`: per-sprite palette indices exported transparent, the sand dune's black crest) |
| `export_fullscreen.py` | `assets/fullscreen/`: every fullscreen BIN (`NAME.png`, `STAGE0N_NAME.png`) in its own palette |
| `export_projectiles.py` | `assets/stage00/` projectiles |
| `export_player.py` | `assets/player/`, plus `VARIANT_SPRITES` (the DESERT 2 turret in the day palette) |
| `export_hud.py` | `assets/hud/` |
| `export_animations.py` | `assets/effects/` |
| `export_fonts.py` | `assets/fonts/` (`overkill0`..`overkill4`: one OVERKILL banner per mission in its stage palette; `credchars`: HICHARS in the CREDITS palette) |
| `export_mainmen.py` | `assets/mainmen/` (words, generated arrow cursor), `assets/mainmen/font/`, `assets/fonts/mainmen.*`, `assets/fonts/main.*` (plus `content/fonts/main_synth/`); runtime menu palette in `MENU_PALETTE` |
| `export_screens.py` | CREDANIM / HIANIM (CREDITS / HISCORE palette, fixed frame box via `menutitle.py`), POWCOUNT, OKBADGE, KILLICON, BURN, PHASE cards |
| `export_mission.py` | `assets/mission/` |
| `export_mission_text.py` | `assets/mission_text.json` |
| `export_sounds.py` | `assets/sounds/`, `assets/sounds.json` |
| `export_phend.py` | `assets/phend/` |
| `export_shop.py` | `assets/pow/` sprites, `assets/pow/weapon_info.json` (WINF / WINFT prices and descriptions), `assets/fonts/charspow.*`, all in the `POWUP.BIN` palette (disabled buttons grey out 224 / 215; run after `export_fonts.py`) |
| `export_equip.py` | `assets/equip/` in the `EQPCHP.BIN` palette, `layout.json` template-matched on the backdrop index maps |
| `export_music.py` | `assets/music/menu.med`, `hiscores.med`, `ending.med`: `SEEKMOD.BIN`, `SEEKHMOD.BIN`, `SEEKEMOD.BIN` as they are |
| `export_ending.py` | `assets/ending/ending.json` (story text read from `SEEK.EXE` at the registered release's addresses, layout from its code), `reganim.flc` (CD release), `assets/fonts/endstory.*` (ENDCHARS in the FIN01 palette, with its drop shadow) |
| `decode_level.py` | Stage BIN -> JSON (`--summary`) |
| `decode_blitter.py` | Exact world-sprite decoder |
| `decode_planar.py` | Exact planar HUD sprite decoder |
| `unjam.py` | `DATA.JAM` / `DATA.JAL` lister and extractor |
| `decode_palette.py`, `decode_sincos.py`, `decode_stage_assets.py`, `decode_font.py`, `decode_fullscreen.py`, `decode_fullscreen_v2.py` | Viewers / dumps (need Pillow, numpy) |

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
| Delete | Free play: wreck the own vehicle (crash picture test). Overview: preview the game-over picture, Shift the one before a respawn |
| F7 | Co-op free play (vehicle select) |
| F8 / F9 / F10 | Animation / font / sound gallery (overview) |
| F11, Shift+F11 | Ending, VIC3's alternate ending, with the preview stats (overview) |
| F9 | Radar auto zoom (in game, rebindable). Co-op: P1 Tab, P2 keypad `.` |
| F12 | Screenshot (rebindable) |
| Overview: wheel, +/- | Zoom |
| Overview: Tab, PgUp/PgDn | Stage picker / cycle (also in free play, never in a campaign) |
| Overview: L, G | Segment lines, 256 px grid |
| Overview: V, O | Vehicle, optional game over |
| Overview: C, [ ] | Axis-aligned pickups, `speed_scale` |
| Overview: S | Save `data/entity_types.json` |
| Esc | Back (menu in game) |
| Gamepad | Left stick or d-pad: drive (stick turn is analog). Right stick: strafe / turret. A or RT fire, LB or LT strafe, B take off / land, Y or RB weapon, X radar zoom, BACK pause, START menu. Buttons rebindable (CONTROLS, DEVICE GAMEPAD); the sticks and START are fixed. Menus: d-pad or left stick, A / START confirm, B / BACK back. Co-op: per player, see `vehicle_select`. |
| Mouse (`mouse_control`) | Pointer offset from the vehicle is the stick: sideways turns, ahead drives, behind reverses. Left button fire, right strafe, middle take off / land, wheel next weapon (instead of the view zoom). Single player. |
| Touch | Stick: drive. Buttons: FIRE, STRAFE (modifier), LAND, WEAPON, MENU. Tap commits a high-score name. Desktop test with `love . --touch`: left mouse is the finger, `Z` holds FIRE. |

On the web build (`love.system.getOS() == "Web"`) the window is not resizable;
the page scales the 1280x720 canvas to the viewport. Lowpass filters are skipped
when `love.audio.isEffectsSupported()` is false. The main menu shows FULLSCREEN
instead of EXIT (a page cannot close its tab); it prints `OSPAGE-FULLSCREEN`,
and `tools/web/seek.js` toggles the page fullscreen. The OPTIONS DISPLAY page
drops FULLSCREEN and WINDOW SIZE there, and `Display.apply` ignores their
persisted values (the canvas stays 1280x720, windowed). love.js copies the save
directory to IndexedDB only on `beforeunload`, so `tools/build_web.sh` patches
its `love.js` to hand the private `FS` to `Module.onSavesLoaded` once the saves
are read back; `seek.js` then hooks `FS.trackingDelegate` and syncs about 100 ms
after every write, delete or rename in the save directory, and again when the
page is hidden.

`usedpiscale` is off (`conf.lua`, `Display.apply`): units are pixels on every
platform. On Android and iOS `Display.view_scale()` (screen height / 720)
multiplies the camera zoom, the player sprite scale (`Camera:zoom_ratio`) and
the HUD scale. PostFX shaders request `highp` on OpenGL ES; `effect` parameters
stay `mediump` (LOVE's prototype) and the texture coordinate comes from
`VaryingTexCoord`.
