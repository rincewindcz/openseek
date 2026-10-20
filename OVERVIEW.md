# OpenSeek

Lua / Love2D 11.x reimplementation of *Seek & Destroy* (SAFARI Software, DOS,
1993-1995). No original code is reused. Original art, sound and level data are
decoded from the user's own copy of the game and are never distributed.

## 1. Repository layout

| Path | Contents |
|------|----------|
| `main.lua` | Entry point: game data check, shared `app` context, scene registration, `love.*` callbacks. |
| `conf.lua` | Window configuration; the window icon `content/icon/openseek.png` (not on Windows, where the exe carries the icon, nor on the web). Under LOVE 12, supported experimentally, it allows the OpenGL renderer alone (`t.graphics.renderers`). |
| `engine/core/` | No game knowledge: class, config, input, gamepad, mouse stick, rng, display, camera, animation, audio, font, screen, screenshot, scenes, assets, flic, mathx, log. |
| `engine/game/` | Simulation and gameplay presentation systems. |
| `engine/ui/` | Screens and widgets. |
| `engine/editor/` | The map editor behind `scenes/editor`: document, catalog, view, tools, panels, dialogs, checks. |
| `engine/scenes/` | One scene per top-level mode. |
| `engine/dev/` | Debug panel, determinism self-test, photo mode. |
| `lib/` | Self-contained modules with no game or LOVE knowledge: `json.lua` (excluded from lint) and `strict_math.lua` (`sin`, `cos`, `atan`, `atan2`, `deg`, `rad` built from `+ - * /` alone, so they return the same bits on every platform; linted with `std = "min"`). |
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
  high scores; the shareware plays its own short ending (DEMO01..03, DEMOOVER, closed
  by a get-the-full-game-data call), then the same credits and high scores. Vehicle variants whose hull /
  turret (or chopper) frames are not in the pack are dropped from the list
  (`game/vehicles.lua`; the shareware keeps tanks GREEN, DESERT, ARCTIC).
- Files in `content/` must not contain pixels copied from the game or from
  `assets/`. Palette-bound sprites are white-on-alpha masks tinted at draw time.

| `content/` file | Notes |
|-----------------|-------|
| `hud/player_f00..f03.png` | Co-op score labels P1-P4, 8x6 masks, 3x5 glyphs. |
| `fonts/main_synth/{B,J,K,Q,Y,Z}.png` | Menu word-art letters absent from `MAINMEN.BIN`. |
| `intro/openseek_intro.png` | openSEEK engine card, 1920x1080, shown before TITLE (`engine_intro`) and behind `MISSING GAME DATA`. |
| `intro/openseek_intro.ogg` | The engine card's riff, about 5.6 s, started with the card and ringing on over TITLE. |
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
   simulation state. Its trigonometry comes from `lib/strict_math.lua`, never
   from `math.sin` and its relatives, and it squares by multiplying, never by
   `^`: those differ in the last bit between platforms and Lua runtimes.

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
love . --verify [replays/a.osr ...]   # play recordings back, check every checkpoint
love . [stageMP]
love . --touch                # phone controls on a desktop (see below)
love . --photo [stageMP]      # developer photo mode (see below)
love . --dev                  # developer run: the launch keys, the debug panel, the cheat keys
```

`--dev` marks a developer run (`app.dev`); `--photo` implies it. Without
either:

- The main menu's launch keys do nothing: `F1` (fly the loaded stage freely),
  `F3` (sandbox), `F4` (replay panel), `F7` (co-op free play), `F8` / `F9` /
  `F10` (galleries), `F11` (ending preview), `Delete` (crash picture). The map
  editor's DEV menu, which holds the same entries, is not shown.
- The developer keys in play do nothing: `F2` (debug inspector), `F5` (god
  mode), `F6` (pickup override), `E` (weapon level), `Delete` (self-destruct)
  and the stage step in free play (`PgUp` / `PgDn`).
- `R` restarts a stage in free play only; in a campaign it would be a free
  retry.

`--touch` turns the left mouse button into a single touch (the pointer moves
only while it is held, as a finger would) and makes `Z` hold the on-screen FIRE
button as a second touch, so the stick and FIRE work together. The controls show
from the start and OPTIONS gains the MOBILE UI page. The OS cursor stays
visible. Other mouse buttons and the keyboard behave as usual.

`--photo` enables photo mode (`dev/photo_mode`), a developer tool for
promotional stills; without the flag the module is never loaded. `F8` in
gameplay or co-op opens it (`F1` on the main menu flies the loaded stage): the
simulation holds as in a pause, the HUD and
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
| `--verify` | any simulation code, with recordings from the same version at hand; on each platform before a release |
| `luajit tools/sim_maps.lua` | `game/map_file`, `game/map_compiler`, `game/roads`, `World:load`, a map's placed pickups in `game/powerups`, `engine/editor/` (document, catalog, ops, validate, goals, selection, prefabs), a map's objectives in `game/mission`, the helicopter count of `game/enemy_heli`, the stage exporter |

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
- An unhandled error ends in `ui/error_screen` (`love.errorhandler`), which names the GitHub issues page for the report.

| Scene | Role |
|-------|------|
| `title` | Engine intro card on the first launch or while `engine_intro` is on (about 3 s; its riff rings on over TITLE and holds the menu music back; Enter, Space, Esc skip to TITLE), then the TITLE card; Enter, Space, Esc skip to `main_menu`, or to `style_select` until `Config.style_chosen` is set. |
| `main_menu` | Main menu (NEW GAME, RESUME, OPTIONS, CREDITS, HIGH SCORES, LOAD, ADVANCED, EXIT, or FULLSCREEN on the web); pushed over a running game on Esc, where RESUME pops back to it. Otherwise RESUME reopens the campaign autosave at its briefing. NEW GAME replaces it with `new_game`. Under `--dev` the fresh menu takes the launch keys of section 4 (`MainMenu:_dev_key`). |
| `advanced_menu` | ADVANCED submenu, same widget and backdrop: MISSION, EDITOR, REPLAYS, BACK. Keeps the non-run entries off the main menu. EDITOR (the map list and the map editor) is left out on the web and phone builds and under `--touch` (the editor is a mouse and keyboard tool). |
| `new_game` | NEW GAME mode menu: SOLO CAMPAIGN, LOCAL COOP, CANCEL. |
| `vehicle_select` | Per-player CHOPPER and TANK variant cards over the unused original `VSELECT` art (preview boxes, camo strips, OK / EXIT plates) with turntable previews; the active card names its variant in the gold `credchars` font, its letters closed up by up to 2 px when the name is wider than the gap between the arrows (the co-op columns). Campaign: START begins the run. Free (F7): the focused card is the vehicle; G toggles god mode. Two players: a CONTROLS line per column (`1` / `2` or a click cycles AUTO, KEYS, PAD 1, PAD 2 into `coop_device_1` / `_2`, showing what AUTO resolves to and a named pad that is missing); a pad steps the column of the player holding it. |
| `ending` | The original's ending after the last stage (`Campaign.complete`): `assets/ending/reganim.flc` (CD release only) through `core/flic` at `anim.frame_time` with its frame cues and two fading engine loops, then the `ending` music under FIN01..03 and VIC1..3 (the shareware: DEMO01..03 and DEMOOVER, no animation, with `extra_lines` appended under DEMOOVER). Each picture fades in, holds, types `assets/ending/ending.json` lines in `fonts/endstory` at fixed 8 px pitch (`char_time` per letter, a tab pauses `tab_pause`), shows the prompt and waits. A key completes the picture's text, then moves on; a key skips the animation; Esc skips everything. `enter{ alternate, record, scores, preview, keep_music, on_done }`; `alternate` types VIC3's alternate ending, `preview` falls back to `data/ending.json` `preview` without a record (overview F11), `keep_music` leaves the end music playing into the credits (`Campaign.complete`). EXTRA `ending_stats` adds the run record under FIN01..03 (DEMO01..03). |
| `credits`, `hiscores` | Info screens over `ui/info_screen.lua`. Credits: `data/credits.json`, openSEEK first in the large style (`main` heading, `credchars` name), then the original team under a `credchars` label in the small style (`credchars` heading, `chars` name); `enter(on_exit)` replaces EXIT's return to the menu (the ending passes the high scores). High scores: top-10 table in the gold `credchars` font (`hichars` fallback) with name entry (up to 40 characters), one per qualifying player after a co-op run; a name is held to the column left of its score through `ui/scroll_text`, following the caret while typed and panning to its end and back when stored. The shipped table (`data/highscores.json`) is the original's own default names and scores under the port's author. |
| `advanced_settings` | OPTIONS: STYLE (the GAME STYLE row, and PREVIEW STYLES opening `style_select`, dimmed and inert while a game is suspended underneath), DISPLAY, VIDEO, EFFECTS, AUDIO, CONTROLS, MOBILE UI, GAMEPLAY, DIFFICULTY, EXTRAS. MOBILE UI only where `TouchControls.available` (web, Android, iOS, `--touch`); the web build drops DISPLAY's FULLSCREEN and WINDOW SIZE. The sidebar packs tighter when it holds more than nine entries. Rows scroll when a category holds more than `MAX_ROWS` (9). CONTROLS: a DEVICE row switches the action rows between KEYBOARD and GAMEPAD, each with two binding columns (Enter captures the next key or pad button, Del clears a slot), RESET TO DEFAULTS restores the shown device, then STICK DEAD ZONE, MOUSE STEERING and MOUSE SPEED. Over a suspended game the footer of a row the phase holds its own value of (`Replay.PARAMS`, the difficulty preset, the game style) says that it takes effect next game. |
| `mission_briefing` | Briefing text, phase selectors, SAVE / LOAD / SHOP / PLAY. Rewrites the autosave on every open in a campaign run. A map briefs with its own name and paragraphs over the backdrop of its art set's mission, without the icon column, and under its name stands its author. A closed button is darkened and skipped by pointer and keys: SAVE and LOAD on every map (a map played on its own is no run), SHOP on a map that fixes the loadout or sets `equip.no_shop` (`MissionBriefing.closed`). |
| `mission_select` | Debug mission / phase picker with a separate medal purse. |
| `equip` | Vehicle and weapon-bay selection; skipped without `assets/equip/`. One special is always loaded. Co-op: once per player (tagged), EXIT steps back a player. |
| `shop` | POWUP / POWUPT weapon shop. Co-op: once per player, each with their own purse. |
| `map_select` | MAPS screen (menu ADVANCED / EDITOR), built like `saves` over an amber-tinted `MAINP`: the maps of `maps/` in the save directory, newest first, under a NEW MAP row. PLAY (Enter, or a click on the row) runs briefing, equip, phase and stats and comes back (`app.play_return`), with the MISSION mode medal purse and no high score entry; 2P (`2`) plays it with two on the split screen, through the vehicle select; BEST (`B`) plays back the recording of the fastest win. A map made for one or for two players only (`players`) offers that way alone. Two lines under the list describe the highlighted map (author, players, night, weather, difficulty) and give its records (`game/records`); a new record is announced on the way back. EDIT (`E`) opens the editor; COPY (`C`) duplicates; two-step delete; FOLDER (`F`) opens the directory. A map with a check error (section 6a) is listed but not played. A map file dropped on the window is imported (`Scene:filedropped`). |
| `editor` | Map editor (section 6a). Entered from `map_select` with `{ map = name }` or `{ new = true }`; with nothing it resumes the map already open (after a try). Key repeat is on while it is the top scene. Under `--dev` its DEV menu launches the sandbox, co-op free play, the replay panel, the galleries, the ending previews and the crash picture. |
| `gameplay` | Player-locked rotating camera, combat. A phase played on its own returns to where it was started (`GameplayBase:leave_run`, `app.play_return`: the map list or the editor, else the menu); a map tried from the editor leaves on Esc and is not recorded. Under `--dev` `PgUp` / `PgDn` step the pack stage in free play. |
| `sandbox` (F3 on the main menu, `--dev`) | Gameplay plus live vehicle parameter editor. |
| `style_select` | Style selection screen, a `gameplay` subclass: three style cards (CLASSIC, ENHANCED, OVERKILL, on the VSELECT camo strip the style's `camo` names), the chosen style's one `about` line, a DIFFICULTY row, a fixed line pointing at the options for a style of one's own, and the OK plate over a live phase, unrecorded, silent and in god mode. The phase is flown by the scripted runs of `data/styles.json` `preview` in turn, each entered as a new phase on its own stage and started inside an enemy base. Nothing holds the replay parameters fixed during a run, so a choice is written to `Config` and shows at once. Opened by `title` until confirmed once (starts on the `default` style, no way out but OK), and by OPTIONS with `return_to`, where Esc restores every `Config` scalar. Leaving reloads the stage that was loaded before. |
| `coop_gameplay` (F7, LOCAL COOP, a map's 2P) | Split-screen two-player co-op; full screen when one player is left in a campaign. |
| `replays` (F4 on the main menu, `--dev`) | Dev replay panel: play back, verify, toggle recording, delete. |
| `replay_select` | REPLAYS screen (menu ADVANCED), built like `saves` over a blue-tinted `MAINP`: watch a recording, two-step delete, left / right (or the label) step the order between newest, oldest and by progress, stage / mode / players / running time of the highlighted one, flagged when it was recorded on another version of the game or on another platform. Playback returns here through `app.replay_return`. |
| `saves` | SAVE / LOAD slots over the green-tinted `MAINP` backdrop: unlimited named slots, scrolling, name entry (up to 40 characters; the field follows the caret, the highlighted slot's name pans when wider than its column, `ui/scroll_text`), two-step delete. Opened from the briefing (both modes) and from the menu LOAD entry. |
| `anim_gallery`, `font_gallery`, `sound_gallery` (F8/F9/F10 on the main menu, `--dev`) | Asset galleries. |

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
| `core/audio` | Clip catalog, event table (clip lists, per-vehicle variants, size pitch), callouts and sequences, voice pools, buses, ducking, music (`.ogg`, `.mp3`, `.med`; an `.ogg` / `.mp3` beats a `.med` of the same name), one-shot jingle on the music bus. |
| `core/font` | Bitmap fonts from `assets/fonts/`; mask (tinted) or truecolor. `print` `cell` option draws fixed-pitch at each glyph's in-frame x offset. `for_mission(name, m)` returns the cut a mission ships for its own HUD palette (`chars3`), else the shared font. |
| `core/screen` | Fullscreen image fade in / hold / out, with an optional `fx` object animating the picture (`update`, `cue`, `draw`; `cut` skips the fade-in). `is_closing` reports the fade-out. |
| `core/flic` | FLI / FLC player: decodes one frame per `next_frame` into an index buffer and an RGBA `image` (COLOR_256 / 64, DELTA_FLC / FLI, BYTE_RUN, BLACK, COPY); the caller sets the pace. |
| `core/mathx` | `heading_deg`: the game's angle convention over `lib/strict_math`. |
| `core/log` | Timestamped, tagged console lines (`info`, `warn`); `recent()` keeps the last 80 for the crash report. |
| `core/version` | Build identity from `build.json` (`version`, `commit`, `dirty`). `string()` for the startup log line; `draw()` puts the build tag in the bottom-right corner of the title, the main menu and the mission select: `OPENSEEK <version>` in the gold CHARS font (`OPENSEEK DEV` without a release tag) and, on a packaged build, the commit under it in grey (`+` when built with uncommitted changes). |
| `game/world` | Stage load (a pack stage, or a map compiled by `game/map_compiler`: `World.is_map`, `map_stage`, `stage_state`), entities, environment (`world.env`: art set, night, weather, look, music; section 6a), ground colour, collision (`blocked`), objectives, ground dust, `world.time`, `world.rng`, `world.params`. A map that cannot be loaded falls back to the first pack stage. |
| `game/map_file` | Player-made maps: format, compact one-object-per-line encoding, read / write / list / import in `maps/` of the save directory, `hash` (the fingerprint a replay header carries as `map`). Section 6a. |
| `game/map_compiler` | `compile`: map -> the stage table `World:load` builds a phase from. `decompile`: pack stage -> map (a clone). `pack_stage`: the cached class side of a pack stage (classes, assets, uses per class, classes sharing a spot). |
| `game/roads` | `build(roads, size)`: a map's roads as border segments (the outline of all of them together), centre marks and the legs they were built from (the ground each covers), for the compiler and the editor's view and picking. |
| `game/debris` | Explosion shards (`data/debris.json`), owned by the world as `world.debris`: `burst(name, x, y, opts)` throws the named burst, `update` flies the pieces (linear slow-down to rest, sinking through the size rows of their clip, smoke trail puffs, dust puff on landing through `World:add_ground_dust`, then lying on the ground with EXTRA `lying_shards`). Presentation only: fed through the one-way `World:spawn_debris`, random numbers from `math.random`, never read by the simulation. Flying pieces and puffs are drawn by `Renderer:draw_debris`, lying ones in the ground pass over the tread marks. |
| `game/entity` | HP, state machine, damage smoke, hit effects, crater. |
| `game/player` | Movement, collision, altitude, landing, tank turret, fuel, frames, rotors, ammo, death, skins, score, lives. A tank that drives into a solid object lying within `bump_arc` of its travel direction bounces off as in the original: its speed flips to the same share of the opposite top speed (times `bump_bounce`) and it is set back `bump_back` seconds of travel, after which the controls ease it out. Under `bump_min` of top speed, or on a glancing touch, it slides along instead, and stands still when it cannot. A tree it may crush (`explosive_trees`) never bounces it. `Player.draw_tank_variant` is shared with the select screen. |
| `game/enemy_heli` | Enemy helicopter posts (leash, respawn), flight AI, fire, death (`world.air_units`). |
| `game/combat` | Weapons, projectiles, firing geometry, hits, AoE, effects, ground enemy AI. |
| `game/enemy_fire` | Enemy firing rules as the original runs them (owned by `game/combat`, `data/enemy_weapons.json`): a gun's routine (volley, burst, reload per fire level), soldiers and their wander, proximity mines, a hangar tank's parked gun, the helicopters' weapon modes, and the homing missiles' bearing refresh with the radar / radio tower penalty. |
| `game/air_strike` | Air strike (owned by `game/combat`): impact schedule drawn from `world.rng` at the call, detonated on `world.time`, damage in toughness units; EXTRA craft, rocket and bomb visuals with their shadows. |
| `game/mission` | Objectives, progress, return to base. `Mission.for_stage(world, players, stage)`. A map's own objectives (section 6a), their order, the time limit; `order()` and `clock()` for the scene to show. Enemy helicopters are no entities: the helicopter system counts the ones shot down on the world (`air_kills`) and says how many the phase can put up (`air_supply`). |
| `game/rescue` | People to pick up: buildings holding POWs, the crash-site crews, walkers, flung bodies. |
| `game/saboteur` | Agent drop-off and recovery at the linked buildings. |
| `game/powerups` | Power-ups as the original runs them (`data/powerups.json`, times in ticks of 1/70 s). A dying building's drop is drawn from a 16-entry table built per player at phase start: armor and fuel alternating, then `ammo_share` 10 entries split evenly among the carried weapons that have a pickup frame (chain gun and air strike have none), so ammo only drops for what the player carries; free play carries everything. Every other entry turns to fuel or armor while the nearest player is below `low` (fuel 20 %, armor 5), and below `critical` (10 %, 2) the drop is always that supply, fuel first. Medals only come from forced-drop classes. Lifetime `lifetime` 1220 / 976 / 732 ticks by `pickup_level`, blinking the last `blink` 300, frozen while every player is down. Taken inside a `reach` 16 px box around the vehicle centre, by fly-over unless the difficulty says to land on it (medals, fuel / armor); `F6` forces fly-over for everything. Fuel and armor add half the maximum, ammo its `ammo_pickup` up to `ammo_cap` 999. EXTRA `weapon_finds`: a drop is with `find.chance` a weapon of the vehicle that the player does not carry (its icon alternating with the unused GET / ME frames, over the pulsing `find.glow` halo); taking it adds the weapon to the player's list for the rest of the phase with `find.ammo` 15 % of its starting load (at least one round), rebuilds the table and stamps `Player.found_weapon` / `found_time` for the HUD notice. A map's own pickups (`stage.pickups`, section 6a) are laid out when the players are set: they never expire, ammunition for a weapon nobody carries is such a weapon to find, and what no vehicle in the phase can use is left out. |
| `game/difficulty` | Difficulty presets over the difficulty Config keys (`data/difficulty.json`): choices, apply, match; `over` lays the difficulty a map sets for itself over a parameter set. |
| `game/style` | Game styles over the Config keys each one owns (`data/styles.json`): list, choices, apply (also applies the POST FX preset the style names), match, the selection screen's default style and preview runs. `main.lua` applies a named `Config.style` at load, so a style's values follow the data file; `custom` keeps the saved ones. |
| `game/renderer` | Ground pass, object pass (y-sorted, culled), player layer by `is_airborne()`, shrapnel overlay. |
| `game/lightfx` | Night light map and additive flashes (`data/lightfx.json`). A night stage draws its world into a target of its own (`begin_scene`, after `PostFX:begin_world`) and `draw_night` lays it back multiplied by the light map: the mission's ambient tone, a headlight beam and pool per living player (world-anchored, so a split-screen half shows the teammate's), the timed lights of explosions and muzzle flashes, and the lights of live fire. The map holds up to 4 times the art's brightness (float target where the GPU has one), capped at the mission's `max_light`, so a lit pixel comes out brighter than its art. `draw_additive` adds the bursts, the glow of live fire and the screen washes on any stage. Live fire is read from the combat state each tick (`_collect_sources`): rounds in flight and ignited effects whose weapon or clip is listed. With `night_lighting` off the same pass draws the original's night instead: the map holds a mask, the 47 px disc of the original's spot sprite 110 world units ahead of every living player on its axis, and the pixels under it become twice their art plus 16 / 63. |
| `game/postfx` | World-view post-processing and soft shadows (`data/postfx.json`); `enter(world)` picks the stage's mission look; `begin_world(alarm)` takes the view's low armor warning from `game/impact_fx`. |
| `game/impact_fx` | EXTRA hit flash, camera shake and low armor warning (`data/impact_fx.json`), fed by the `World:hit_flash` / `:player_hit` / `:explosion_light` / `:player_death_light` / `:weapon_fired` forwarders and the players after each tick; the shake is a per-camera offset applied in `Camera:apply`, the warning is handed per view to `PostFX:begin_world`. |
| `game/tracks` | EXTRA tank tread marks (`data/tracks.json`): laid from the players after each tick, faded out by age, drawn by the renderer's ground pass as one sprite batch. |
| `game/detail_fx` | EXTRA details (`data/detail_fx.json`): tank recoil and muzzle smoke, chaingun casings, tread dust, wreck smoke, pickup glint (drawn from `Powerups:draw`), target glint (drawn from `Renderer:_draw_entity`). Fed by the `World:weapon_fired` / `:wreck` forwarders and the players after each tick; ground layer drawn in the renderer's ground pass, smoke by `Renderer:draw_detail_air`. |
| `game/sound` | Listeners, panning, attenuation, engine loops, radio queue, situational callouts (section 10). |
| `game/shadow` | Altitude-scaled silhouette shadows, off at night. |
| `game/weather` | Snow (mission 1), rain (mission 2); for maps also blizzard, thunderstorm and sandstorm (`data/weather.json`): a gusting wind, a haze with drifting banks over the world view (`draw_haze`, fitted to the wrap period), lightning through `LightFX:sky_flash` and thunder after it. Presentation, global RNG. |
| `game/vehicles` | Free-play weapon cycles, equip bay and special lists, variants (`data/vehicle_variants.json`, loaded on first use), labels. |
| `game/campaign` | NEW GAME run state: solo run fields or `app.coop_run` (per-player score, lives, threshold, out flag, `Loadout`; lives rule and pool), active players, `advance`, `finish` (out of vehicles), `complete` (last stage cleared: ending, credits, high scores), `resume` (reopen a slot or the autosave at its briefing). `start_team` gives a map played by two a co-op run of its one phase; `coop(app)` is the run in progress, a campaign's or such a map's (while `app.play_return` is set). `app.run_record` sums each cleared phase over all players (`record_phase`, from the gameplay scenes: phases, simulated time, vehicles lost, stats screen kills, rescues, badges). |
| `game/loadout` | Campaign inventory: levels, bays, special (always one, the vehicle's first by default), ammo multipliers, `buy`. `Loadout.info` (cost, description lines) from `assets/pow/weapon_info.json`; `price` = list cost minus `trade_in` (`data/shop.json`) of the owned level's cost. `Loadout.active(app, player)` picks a co-op player's own. `Loadout.for_map` starts a map's fresh inventory under its `equip` rules (`restrict`: the purse, `banned` weapons, weapons handed over at a level, and `locked` areas holding what the map put there); `everything(vehicle, rules, weapons)` is what a try from the editor flies. |
| `game/records` | Records of the player-made maps, on this machine: `records/maps.json` holds per map file its fingerprint and per way of playing (`single`, `coop`) the fastest win, the highest score of a win and whether the fastest run's recording is kept (`records/<map>-<mode>.osr`). `submit` returns what a win beat; `of(name, hash)` is empty once the map's file changed, and the first win on the new one starts over; `forget` goes with an erased map. |
| `game/score` | Kill values, phase bonus weights, bonus-life ladder, `Score.award`. |
| `game/stats` | Destruction categories and stage totals. |
| `game/replay` | Replay header (platform `build`, game `version`), delta input, checksums, `.osr` files; on playback a checkpoint where only the player part disagrees is a drift (`is_drift`), played through and reported, anything more ends it; hands each finished recording to the hosting page when the web build ships `build.json` with `replay_upload`. `Replay.Hold` is a phase's hold on the simulation parameters: the held values go back into `Config` at the start of every tick, the player's own while a menu is up and when the phase ends, edits included. |
| `game/savegame` | Campaign save slots: capture / apply a run (stage, score, lives, bonus ladder, whole inventory, run record; co-op adds a `coop` table per player), one JSON file per slot in `saves/`, plus the `autosave.json` of the run in progress (written by each campaign briefing, removed by `Campaign.finish`). |
| `ui/hud` | Gauges, weapon icon, radar (with per-player auto zoom, home base, pickup, air strike and mission place blips), weapon sights (the air strike's rests on its target), counters, OVERKILL banner, weapon find notice, rolling score. `set_mission` picks the mission's HUD art (gauges, weapon icons, radar, cursor box, lives icon: `assets/hud/stage{m}/` over `assets/hud/`) and `font()` its text font: the night mission's readouts, in-game messages and FPS counter draw in its green CHARS, as in the original. |
| `ui/end_stats` | DESTRUCTION STATS screen: lines count up (icons filling), then wind back down as each pays its bonus into TOTAL SCORE; per-player columns in co-op. |
| `ui/crash_fx` | EXTRA crash picture effects (`data/crash_fx.json`), the `fx` of the crash / game-over overlay: smoke, fire glow, embers and heat haze composed at the picture's resolution, flash and static entrance, static burst on a radio cue (`crash_fx`); the typed cause of the loss (`crash_cause`, from `Player.damage_cause`); the run's trivia (`crash_stats`, from `World.tally` and the campaign record via `GameplayBase:crash_stats`). `CrashFX.show` picks the picture and its timing for both gameplay scenes (the fx is nil with every extra off); `CrashFX.preview` is the overview's `Delete` key. |
| `ui/equip_screen` | Equip widgets over `assets/equip/layout.json`. An area a map closed (`loadout.locked`: bays, specials, the fuel and armour sliders) has no zones and shows what the map put there (its weapon per bay and its special selected, the rest darkened, the sliders dimmed on its split); a weapon a map keeps out (`loadout.banned`) is darkened. |
| `ui/shop_screen` | Original shop flow over `data/shop.json`: select a level icon (description, trade-in COST), PURCHASE buys it. LOADED on the owned level, lower levels darkened and unselectable, medal purse bottom-left (digits, large medal per 10, small per 1). Arrows move over the grid, Enter purchases, Tab switches vehicle, Esc is DONE. `shop_fx` (EXTRA.md) animates the purse, greys levels the purse cannot pay for (not the selected one, whose COST reads red), slides the focus frame, marks the hovered box and dims LOADED while a higher level is selected. |
| `ui/kit` | Immediate-mode widget kit of the map editor: panels, buttons, check boxes, text and number fields, a text box of several lines (`area`: wrapped, Enter breaks a line, the arrows move through the lines as shown), drop-downs, tabs, scroll areas, menus, tooltips, one dialog; a click from one text box into another ends the first edit before the second takes the keyboard; popups and the dialog are deferred to `finish()` and own the input while open. The shipped "Loaded" font, or LOVE's own when VIEW sets the plain one (`Kit:set_font`, persisted as `Config.editor_font`), tinted icon masks from `content/editor/icons/`, theme from `data/editor.json`. UI units are window pixels divided by `kit.scale` (1, 1.25, 1.5 or 2; `Kit.scale_for` picks by window height). |
| `ui/menu` | Main menu over `MAINP`, `main` font (`mainmen` on a pack exported before `main` existed). Also drives the `new_game` and `advanced_menu` submenus. `set_notice(id, text)` makes an entry answer with a line under the last row (`chars` font, 2.2 s) instead of being confirmed. |
| `ui/player_tag` | Co-op player colours, `PLAYER n` badge for the shop / equip screens. |
| `ui/mission_menu` | Briefing menu, button row, objective icons, `assets/mission_text.json`. A paragraph wraps to its column and breaks where its text has a line break; `MissionMenu.lines` gives the lines a text takes beside a card (`SLOT_LINES` fill a slot). The icon under the pointer lights up: its art is added onto itself by as much as lifts the card's mean brightness to `HOVER_TARGET` (the dark night cards about 2.5 times, a day card barely). |
| `ui/mission_select` | `STAGE0X_MPIC` carousel over the missions present, phase buttons. |
| `ui/data_setup` | First-run screen without a usable pack: runs the converter, restarts into the game (section 2). |
| `ui/error_screen` | `love.errorhandler`: writes `crashes/crash_<date>_<time>.txt` into the save directory (error, traceback, build, LOVE, OS, renderer, window, pack status and edition, the last log lines) and shows the error, the report path and the first traceback lines over the dimmed engine intro card, in the shipped TTF, so it works without the pack. `C` copies the report, `O` opens the folder, `R` (pad A) restarts, Esc (pad B) quits; a tap copies on touch builds. Under `--selftest` it prints and exits with status 1 instead. |
| `ui/info_screen` | CREDITS / HIGH SCORES shell. |
| `ui/pointer` | Mouse / touch pointer in 320x240 design space. |
| `ui/layout` | 320x240 design space, letterbox `fit`. |
| `ui/hint` | Two-tone footer key hints: `{ENTER} LOAD` draws the braced key name gold and the action white. |
| `ui/scroll_text` | Text held to a fixed width for typed values: clipped print with an offset, `tail` (the end in view, for a field being typed into) and `swing` (pans a text that does not fit to its end and back). |
| `ui/touch_controls` | Single-player on-screen controls: floating stick (left half), FIRE, STRAFE, LAND, WEAPON, MENU. Held state and analog `turn()` read by `InputSource.Local`, buttons queue edge events. Stick angle from vertical: straight within 8 deg, turn rate linear to full at sideways, drives within 65 deg of up/down, dead zone 0.25 of the radius. Buttons draw their white icon from `content/mobileui/icon_<id>.png` (label when missing), tinted gold or white. MOBILE UI options: `touch_color`, `touch_opacity` (multiplies every alpha), `touch_button_scale`, `touch_stick_scale`, `touch_left_handed` (buttons measured from the left edge, stick on the right half). Drawn while the last input was touch (from the start under `--touch`). |
| `editor/document` | The open map: lookups by id, group and owner, a 128 px grid for picking and culling, the undo history (every change is a recorded redo / undo pair, batched per action), type interning (`type_with`), the roads as built geometry (`built_roads`), the road under a point (`road_at`), moving roads (`move_roads`, `record_road_move`). |
| `editor/catalog` | What can be placed, read from the pack: one entry per sprite and kind of an art set, classes sharing a spot kept as one entry (`stack_share`), `feature` (flag, pad, person, home pad classes, from any art set when the own one lacks them), `type_info` (what a map type draws as), inspector choices (firing routines, soldier and helicopter modes, movements). The pickups a map lays out are entries of every art set (`pickup_choices`, `part_type`, `weapon_users`). `road_style`: how a road of an art set is drawn. |
| `editor/view` | Free camera over the wrapped map in a window rect; draws the document (ground, decals, lines, objects, map copies past the seam shaded), picks under a point. |
| `editor/tools` | SELECT, PLACE, SCATTER, ERASE, ROUTE, LINE, ROAD, MEASURE; `draw_ranges` (what an armed kind sees and where it fires); off the strip, the one-click picks the map settings hand over to (a briefing picture's square, an objective's place). |
| `editor/goals` | The editor's side of a map's objectives: the rows the settings list (the map's entries, then what its content asks for), changes to them as new lists for the undo history, the ids taken from a selection, kind choices, what the objectives mark on the map. |
| `editor/ops` | Placing an entry, the objective marks of a building (people inside, agent target, waiting crew), copy / paste / duplicate of objects and roads (a copy also holds the routes its units drive; `centre` measures it from its middle, a `portable` one brings its routes along), arranging a selection (`align`, `distribute`, `turn`, `mirror`), grouping, `auto_group` of a cloned stage. |
| `editor/cards` | Briefing cards of a map as canvases: `compose` (a map square through `View.draw_region`, or a pack card), `for_map`, `originals` (every card of the pack's briefings), `of_stage` (the cards a copy of a stage starts with), `caption` (a caption cut to what fits, in the pixel lettering of `data/editor.json` `cards`). Also used by `scenes/mission_briefing`. |
| `editor/prefabs` | Prefabs: a copy (`Ops.copy`, centred) saved under a name as one JSON file in `prefabs/` of the save directory; `list`, `save`, `delete`, `encode` / `decode`. |
| `editor/panels`, `editor/dialogs` | The dock (OBJECTS, PROPERTIES, LAYERS, CHECKS) and the dialogs (map settings, new, open, save as, ground generator, keys, questions). |
| `editor/validate`, `editor/generate`, `editor/selection` | Map checks; ground cover at a pack stage's densities; the selected objects and roads. |
| `dev/debug_panel` | Entity inspector and type editor, saves `data/entity_types.json`. F2 in gameplay (`--dev`), also in a map being tried. |
| `dev/selftest` | Scripted phase run three ways, compared per tick (`--selftest`); recordings played back against their checkpoints (`--verify`). |
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

## 6a. Maps and the map editor

A map is one phase made by a player: `maps/<name>.json` in the save directory
(`game/map_file`), holding sprite names, class references into the pack's
stages and coordinates, never pixels. Its stage name is `map_<name>`;
`World:load` compiles it (`game/map_compiler`) instead of reading a stage. The
map list and the editor are reached through ADVANCED / EDITOR.

| Map field | Contents |
|-----------|----------|
| `format`, `name`, `author` | Format version (1), display name, free text. |
| `based_on` | The pack stage a clone was copied from. The file then holds that stage's layout. |
| `base` | The pack stage whose class table the compiled stage starts from. |
| `environment` | `art` (mission digit 0-4: sprites, ground, HUD art, tracers, dust), and optionally `night`, `weather` (`none` / `snow` / `rain` / `blizzard` / `storm` / `sandstorm`; an unknown name is clear skies), `look` (POST FX grade of a mission), `music` (track of a mission). Unset keys follow the art set. |
| `size` | Wrap period in world pixels (1024-4096; the editor offers 2048, 3072, 4096). |
| `vehicle` | `tank` / `chopper` when forced (applies however the map is played). |
| `players` | 1 or 2 when the map is for one player only, or for two on the split screen only. Absent: either. |
| `equip` | What the map changes when the player buys and equips (no `loadout`; `Loadout:restrict`): `medals` (the purse for the shop, 0-99; `Loadout.START_MEDALS` when absent), `no_shop` (the briefing's SHOP is closed), `weapons` (name -> level: 0 keeps a weapon out of the shop and off the vehicle, 1 and up hands it over at that level), and the areas of the equip screen that are closed, each holding what the map put there: `no_bays` with `bays` (per vehicle the weapon of bay 2, 3, ...; the chain gun for an empty bay), `no_special` with `special` (per vehicle a name, `""` for none), `no_chars` with `fuel` / `armor` (0-100). A closed area the map names nothing for holds what the equip screen starts with. Absent when nothing is changed. |
| `loadout` | Set when the map decides what the player flies instead of the shop and equip screens: `vehicle`, `weapons` (name -> level; the chain gun is always aboard), `special`, `loads` (ammunition multiplier, 1-6, as that many bays), `fuel` / `armor` (0-100, the equip sliders), `lives`. `Loadout.fixed` turns it into the equip screen's snapshot. |
| `briefing` | Up to three paragraphs, one per slot of the briefing screen; a paragraph may hold line breaks. |
| `briefing_cards` | The picture beside each paragraph: `{ kind = "view", x, y, size, label }` (a square of the map, `size` world pixels a side, drawn from the map whenever it is shown), `{ kind = "card", stage, slot }` (a card of a pack stage's briefing) or `{ kind = "none" }`. |
| `difficulty` | Set when the map is played on a difficulty of its own whatever the player's is: values of the difficulty keys (`game/difficulty`: `enemy_damage_level`, `enemy_damage`, `enemy_fire_level`, `enemy_fire_rate`, `enemy_aggression`, `pickup_level`, `land_for_medals`, `land_for_supplies`). |
| `objectives` | The objectives in order, each `{ type, label, optional, on_open, on_done }` plus its own fields (table below). `on_open` / `on_done` are the objective's events, as it comes up and once it is done (an event: table below). The first files held `{ destroy, rescue, sabotage }` by name, which is still read. |
| `timers` | Timed events: an event with `at`, fired once the phase is `at` seconds old. |
| `ordered` | An objective is worked on once every required one before it is done. |
| `time_limit` | Seconds the required objectives have to be done in. |
| `hold_agents`, `commander` | Stage global 5 (agents wait until all are in) and the special end. |
| `no_return` | The phase is won with the last objective, without the flight home. |
| `types` | `{ from, class, sprite, set }`: a class of a pack stage and the class fields changed on it, and `across` (maps only: the sprite laid across). Or `{ pickup, weapon, ammo_only }`: a pickup lying on the ground from the start, `pickup` being `fuel`, `armor`, `medal` or `ammo` (then of `weapon`, which gives the weapon to a vehicle without it unless `ammo_only`); its objects are no entities. Or `{ start = player }`: where that player's vehicle is put at the start of the phase and after a crash (the first one placed counts). |
| `objects` | Rows `[id, t, x, y, route, owner, group]` in entity order, 0 for no link. `owner`: the building a POW flag, a landing pad or a waiting person belongs to. `group`: parts placed as one thing. |
| `routes`, `lines` | `{ id, points }`; ground polylines `{ color, points }`. A shape's first point is on the map, each next one where it lies from the one before: past the seam (outside 0 to `size`) when the shape crosses it. |
| `roads` | `{ id, points, width, pitch, edge, across, down }`: a road by its centre line. `edge` is the border colour above and to the left, then below and to the right; `pitch` the spacing of the centre marks (0 for none); `across` / `down` the mark's type on a level and an upright leg (`{ from, class, sprite }`). |

An event (`Mission:_fire`, in this order; objects are ids):

| Field | When the event fires |
|-------|----------------------|
| `show` | The objects come in: until then they are not on the map. Entities, helicopter posts (their helicopter waits off the map, `HeliSystem:hold`) and pickups (`Powerups:hold`). |
| `hide` | The objects are taken off the map, without a wreck; a post's helicopter leaves the air and none comes from it. |
| `destroy` | The objects blow up as if shot (`Entity:blow_up`): explosion, wreck, drop, no points. |
| `drive` | The units stand (`Entity.parked`) until then, then drive their routes. |
| `open_fire` / `hold_fire` | Guns and mines do nothing (`Entity.silent`) until then / from then on. |
| `shell` | `{ x, y, radius }`: enemy shelling (`AirStrike:shell`, `shelling` of `data/enemy_weapons.json`) on the place, hitting the players and what stands there. |
| `add_time` | Seconds added to the time limit (`Mission.time_limit`), taken off when negative, never before the present. |
| `weather` | The weather from then on (`none`: clear skies); the scenes apply `world.env.weather` each frame. |
| `say` | A line shown to the player. |
| `ends` | `win` / `fail`: the phase is won or lost there and then. |

| Objective `type` | Fields | Done when |
|------------------|--------|-----------|
| `targets` | | Every mission target is destroyed. Follows from the content. |
| `rescue` | | Everybody on the map is picked up; `optional` makes it a chance taken on the way. Follows from the content. |
| `sabotage` | | Every agent is back aboard. Follows from the content. |
| `destroy` | `objects` (ids) or `kinds` (entity kind names), `count` | All of them, or `count` of them, are destroyed. They show on the radar while the objective is worked on. |
| `reach` | `x`, `y`, `radius`, `land` | A vehicle is inside the circle; with `land`, down or stopped in it (`Player:is_stationary`). The place shows on the radar. |
| `survive` | `seconds` | That long has passed since the objective came up. |
| `collect` | `count` | That many medals were picked up in the phase. |
| `protect` | `objects`, `losses` | Never in the way of a win; the phase fails (OBJECTIVE LOST) once more than `losses` of the objects fell. |
| `air` | `count` | That many enemy helicopters were shot down in the phase, by anybody. No more are asked for than the phase can put up: none without a helicopter post, the number of posts when no post sends another. |

The three that follow from the content need no entry: an entry words them and
places them in the order, one left out is added after the listed ones, and one
with nothing of it on the map is skipped. An objective whose objects are gone
or cannot be destroyed is satisfied at once.

Compiling:

- The stage starts as the class table of `base`, so the classes the engine
  addresses by index (projectiles, walker class 20, helicopters) keep their
  place. Every map type is appended as a class of its own, its sprite read from
  the pack stage it names (`render.dir`). A type this pack cannot resolve
  leaves its objects out (`stage.missing`).
- The original's links are written back in its form: a pad or person class
  gets `parent_class` = its owner's entity index (one class per owner), and a
  POW flag is emitted right after its building.
- `stage.environment` feeds `World:_set_environment`; `stage.mission` (name,
  briefing, author, vehicle, players, loadout, equip, difficulty, objectives,
  `ordered`, `time_limit`, `no_return`) replaces `data/missions.json`. An objective's object ids become
  places in the entity list, which `World.placed` resolves (a turret to its
  hull); `Mission.for_stage` merges the listed objectives with the ones the
  content asks for.
- Roads become what a stage of the original holds for them (`game/roads`):
  border lines among the ground segments and centre marks as decals after
  everything the map places. A road runs level or upright; a leg between two
  points that is neither goes level first, then upright, and a road ending
  where it began is a ring. The borders are the outline of all the roads
  together, so a road ending on another opens the border it meets, a crossing
  opens all four and a bend is closed around its corner. Marks are spaced
  evenly at about `pitch` along a leg and left out where a leg running the
  other way covers the spot.
- Objects of a pickup type are left out of the entity list and become
  `stage.pickups` (`{ kind, weapon, x, y }` in object order), which
  `Powerups:set_players` lays out. So are the starts: `stage.starts[player]`
  is the first one placed for that player, and `World:start_of(player)` the
  free spot at or near it (nil on a stage without one: the base pad).
- An objective's events get their objects as places in the entity list
  (`spec.on_open`, `spec.on_done`), the pickups among those to show or hide
  as places in `stage.pickups` (`show_pickups`, `hide_pickups`); so do the
  timed events (`mission.timers`). `World.placed_posts` turns an entity place
  into a helicopter post.
- Routes, ground lines and roads are compiled from their points as stored,
  so a shape over the seam runs across it: the ground segments and road
  borders reach past the edge (each map copy draws them), the road marks are
  wrapped onto the map. The stage carries `wrap_routes`: a unit drives its
  route the short way (`World:delta`) and its position wraps
  (`Entity:_patrol`). A stage of the original drives its waypoints as they
  are.
- `World:_fit_wrap_period` is skipped: a map's `size` is its period. A clone
  states the period the fit gives its stage.
- `tools/sim_maps.lua` holds the contract: every pack stage decompiled, encoded,
  decoded, compiled and loaded resolves to the same world as the stage itself.

Environment (`world.env`): `art`, `night`, `weather`, `look`, `music`. A pack
stage takes all five from its mission digit. `World:is_night()` is the light
(light map, no aircraft shadows); `World:dark_art()` is the night palette (the
player's and the air strike's night sprite sets, the original's night spot). A
night over a day art set uses `night.default` of `data/lightfx.json` and is
always lit by the light map.

Playing: PLAY in the map list loads the map, sets `app.play_return` and opens
the briefing; the phase ends back in the list. No campaign state, no high
score, a fresh MISSION mode inventory under the map's `equip` rules
(`Loadout.for_map`: its purse, the weapons it keeps out or hands over, the
areas of the equip screen it closes and what they hold). The
briefing names the map's author under its name and shows SAVE and LOAD closed. A map with a `loadout` goes
from the briefing straight into the phase with it (SHOP is closed) and starts
with its `lives`; the replay header records all of it, as for any phase. The briefing
shows the map's cards (`editor/cards`) in the icon column: a map square is
composed in the original cards' shape (the art set's slot number, the frame, a
caption in small yellow pixel letters like the ones painted into the original's
cards, about ten of them), a pack card is copied with the number of its new slot. Replays record the stage name and the map
file's fingerprint (`map`); the replay list marks a recording whose map is
gone (not playable) or changed since.

Two players (2P in the map list): the vehicle select, then
`Campaign.start_team` makes a co-op run of the one phase, each player with the
single-mission inventory under the map's rules and `Score.START_LIVES`
vehicles (a fixed loadout's `lives`), under the lives rule of the options.
Briefing, SHOP and equip go once per player as in a co-op campaign; a fixed
loadout is given to both. The phase ends back in the list, a game over too.
A player starts on the map's start for that player (`World:start_of`) and
comes back to it after a crash; without one the team starts side by side on
the base pad, which stays the place to return to and to refuel at.

Records (`game/records`): a win of a map played from the list (not a try, a
playback, a god mode run or a run not recorded) is submitted with its
simulated time and the team's score, `single` or `coop`, under the level it
was played on (`GameplayBase:record_map_run`, `Records.level`): the
difficulty preset the phase's parameters match (`custom` for none), or `map`
when the map sets its own. The fastest win keeps its recording. The list
shows the records of the level the map would be played on now, with the
preset's name; BEST plays the recording of the lone player or of the team,
the one lit on the record line (left / right or a click on it picks the
other) through the replay path (`app.replay_return = "map_select"`). They
belong to the map's file as it stood: a changed map starts over.

Events: an objective of a map fires its events as it comes up and once it
is done (`Mission:_fire`), and a timed event once the phase is that old
(`Mission:_update_timers`, on `Mission.age`, the clock of the time limit).
What an event waits to do is kept from happening until then
(`Mission:_prepare`): what it shows is held back, the units it sets off are
parked, the guns it opens fire with are silent. A held entity (`Entity.held`) is not there: it is not
alive to anything that sees, hits, blocks or draws (`Entity:is_alive`), does
nothing, and is no kill either (`Entity:is_destroyed` is what the objectives,
the stats and the rescue count). Once brought in it is marked for the open
objective it belongs to. An objective with nothing to do never comes up and
holds nothing. The lines the events say are queued in `Mission.messages`; the
scene shows each for 6 seconds under the objective line. On the split screen
the objective line, the clock and the events' lines are drawn in each half.

In the phase of a map (`Mission.def.announce`) the objective at hand is shown
for 4 seconds whenever its line changes, worded as the map words it, and a
clock runs over it while there is one: the hold-out when that is the objective
at hand, else the time limit (`GameplayBase:draw_orders`, `Mission:order`,
`Mission:clock`). A stage of the original shows neither. A map's `difficulty`
is laid over the player's own parameters when the phase takes its hold
(`GameplayBase:seed_phase`, `Difficulty.over`), so it is in the replay header
and the player's options are untouched; the map list names it (ALWAYS HARD,
OWN DIFFICULTY).

The editor (`scenes/editor`, `engine/editor/`, `ui/kit`):

| Area | Contents |
|------|----------|
| Top bar | FILE, EDIT, ARRANGE, VIEW, MAP, (DEV,) HELP menus; map name (`*` when unsaved), art set, night / weather icons; the check state; TRY. |
| Tool strip | The seven tools, undo / redo, grid, snap, home. |
| Options bar | The active tool's settings and a one-line hint. |
| Dock | OBJECTS (catalog by art set and category, the prefabs, search), PROPERTIES (the selection, or the map summary), LAYERS (show / lock per layer, view toggles), CHECKS. |
| Status line | Last message; pointer position, zoom, selection and object counts. |
| View | The map unlit and north up, copies past the seam shaded, the seam outlined, routes with an arrowhead on each segment long enough for one (the way it is driven), owner links, objective badges (targets, people, the home pad, what an objective of the map's own names, its places as circles), the overview map. The points of a route are numbered on the routes in hand (the one last touched, those of the selected units) and, from zoom 1 x, on every route while the ROUTE tool is out. |

| Tool | Behaviour |
|------|-----------|
| SELECT `V` | Click picks the topmost object, a second click on it the one beneath. Shift adds or removes. Dragging empty ground draws a box; dragging a selected object moves the selection (snapped when snap is on; along one axis with Ctrl held). Right click or Esc clears. A group is picked whole unless SINGLE PARTS (`Tab`) is on. A road is picked by a click on its ground where no object lies, and by a box that holds all its points; selected roads move, nudge, copy, cut, paste, duplicate and delete with the objects, and PROPERTIES sets their WIDTH and CENTRE LINE. With anything selected the options bar offers to save it as a prefab; with two objects or more it shows the ARRANGE entries as buttons. |
| PLACE `P` | The entry picked in OBJECTS follows the pointer; click places, drag lays a row at the sprite's pitch. An armed object shows what it will see and where it will fire while it follows the pointer. A prefab follows the pointer whole, roads included, and a click stamps it. The home pad is one of a kind and leads the entity order: placing it again moves it. |
| SCATTER `B` | Paints the ticked entries at random inside the brush: RADIUS, PER DAB, GAP. One stroke is one undo step. |
| ERASE `E` | Removes what the brush touches: scenery and ground, or everything visible. |
| ROUTE `R`, LINE `L` | Click points, Enter or a double click finishes, Backspace takes the last back. A point drags, a click on a segment inserts one, `Delete` removes the point or shape under the pointer. A click on an end of a shape carries it on from there: the points clicked next are added to it, before its first point when that is the end clicked (Enter or a right click ends it, Backspace takes back only what was added). A route drawn while units are selected is theirs. Lines take a colour from the options bar. With Ctrl held a new point, or a dragged one, sits at a multiple of 45 degrees from the point before it. |
| ROAD `O` | Draws a road as the original's bases have them: two border lines and a dashed centre line. Click points along its middle, Enter or a double click finishes; a point goes level or upright from the one before, and the ground the road takes shows while it is drawn. A point on or near another road (half its width plus `roads.join`) is put on that road's centre line, so the two join. A click on an end of a road carries it on from there, as with a route. A point whose leg comes within `roads.join` of the line of the road's first point is put on that line, so a road is brought back onto its first point without aiming and closes as a ring. A point drags, the points beside it following so the legs stay level or upright (both ends of a ring as one); Shift + click on a road adds a point, `Delete` removes the point or road under the pointer. WIDTH and CENTRE LINE on the options bar set the road in hand, else the next one. Colours, width, mark spacing and mark sprites come from the map's art set (`Catalog.road_style`). |
| MEASURE `U` | Drag from one place to another (Ctrl: 45 degree steps): the line's length in pixels, across and down, and the seconds each vehicle takes over it at full speed (`Catalog.travel`: the vehicle and the load of fuel and armour the map fixes, else both vehicles as the equip screen starts them, at the player's `speed_scale`). The line stays until the next one, a right click or Esc. |

- Catalog entries are built from the pack per art set: one per sprite and kind,
  the classes the original sets on one spot kept together (tank hull and
  turret, gun and base, radar and dish, hangar tank with its hut). Any art
  set's sprites can be placed on any map. A hut draws above the tank inside
  it, as in play, on the map and under the pointer; the entry's picture shows
  the tank part way out (`Catalog.ride_out`).
- PICKUPS (the same on every art set): fuel, armour, a medal, and the
  ammunition of each weapon, placed, scattered, moved and copied like any
  object. They lie there until taken, by the landing rules of the difficulty.
  Ammunition for a weapon that is not aboard gives the weapon (as a weapon
  find, whatever `weapon_finds` says); with GIVES THE WEAPON off in
  PROPERTIES it is ammunition only, laid out when somebody carries the weapon
  and left for a vehicle that does. For a weapon the vehicle cannot load it
  is left out of the phase, which the checks name when the map fixes the
  vehicle. PROPERTIES changes what a placed pickup holds.
- Spare entries (`data/editor.json` `spare`): classes of a pack stage no
  entity uses, rendered by the converter: what the original only leaves
  behind (CRATER, SHELL HOLE, BODY, WRECKAGE 1-7, filed with the ground as
  decals: the type sets `kind` 15) and objects no stage places (FUEL DUMP,
  FIELD HOSPITAL, ROCKS, PIPELINE), with the class data the stage holds for
  them. So a map can start with damage already done. Sheets no class of any
  stage points at are offered on classes the converter borrows (LAUNCH PAD,
  MISSILE TRUCK, SNOW PINE, SNOW ROCK, JUNGLE CRATE, AIRCRAFT HANGAR): copies
  of a class of the same kind and mission, marked `borrowed`.
- PREFABS (the last tab of OBJECTS, the same on every map): SAVE THE SELECTION
  AS A PREFAB (also EDIT, and a button on the SELECT options bar) keeps the
  selected objects and roads under a name, with the groups, the owner links
  and the routes the units drive, measured from their middle. A click on a
  prefab hands it to PLACE; each stamp gets routes of its own. The bin on a
  cell deletes the prefab after a question. A prefab is one JSON file in
  `prefabs/` of the save directory and holds sprite names, never pixels; one
  made on another art set places that art set's sprites.
- ARRANGE works on the selection, a group moving as one: align the sprite
  boxes to the left, right, top or bottom edge of the box around them all, or
  their middles on a column or a row; EVEN GAPS ACROSS / DOWN between three or
  more, the outermost staying; TURN LEFT / RIGHT (`Ctrl+[`, `Ctrl+]`) a quarter
  about the middle of the anchors, and MIRROR (`Shift+H`, `Shift+V`), which
  moves positions only. A turn also lays every sprite that can be laid across
  the other way, and works on a single object.
- LAID ACROSS (PROPERTIES, on buildings, trees, scenery and ground decals but
  hangar huts): the sprite is mirrored over its diagonal from the top left, so
  an upright one lies level. The original lights every sprite from the top
  left and bakes its shadow to the lower right, both of which this keeps; the
  details come out mirrored. Its arc frames are no other way of standing: frame
  16 is frame 0 turned a quarter, shadow and all, and the arc has no 180 or
  270 degree frame. A type field (`across`) the compiler carries to the class;
  `World` marks the class's image and the renderer (with the hit flash, glint,
  highlight and the lock sight's centre) draws it as a quarter turn flipped top
  to bottom (`Catalog.draw_sprite` in the editor). Only drawing changes:
  collision and hits are circles.
- PROPERTIES edits class fields per kind: toughness, score, mission target,
  drops, missile guidance (radar / radio tower), own base building,
  commander's building, firing routine, movement, route, soldier and
  helicopter weapon, respawn, leash. On a single building: PEOPLE INSIDE (adds
  the POW flag and the pickup pad), AGENT TARGET (adds the drop pad), CREW
  WAITING (adds the people). A changed field makes the object a type of its own.
- LAYERS: base, units, guns, buildings, objective marks, pickups, scenery,
  ground, routes, roads, ground lines. SCENERY is locked at first, so a click never picks a
  stone; brushes ignore the lock.
- Undo covers every change (300 steps). Unsaved changes are written aside every
  `autosave_seconds` (`maps/_auto_<name>.json`) and offered back when the map
  is opened again. Leaving with unsaved changes asks.
- MAP / GENERATE GROUND scatters a pack stage's scenery over the map at that
  stage's densities, clear of everything else. NEW MAP starts blank (with a home
  pad and, if asked, ground cover) or as a copy of a pack stage, grouped
  (`Ops.auto_group`), with the stage's briefing: each paragraph in its slot
  and beside it the card the stage shows there (`Cards.of_stage`).
- CHECKS (`editor/validate`): errors keep a map from being played (no home pad,
  no objective, commander rule without its building or without other targets,
  sprites this pack lacks, base stage missing); warnings do not (loose
  objective marks, a route under two points, a hangar tank without a hangar,
  solid objects on the home pad, nothing armed, very many objects, an
  objective with nothing to act on, helicopters asked for that no post sends,
  every objective optional, ammunition the map's vehicle cannot use, a second
  start for a player, a start of player 2 on a map for one, an objective that
  has to destroy what only appears once it is done). Every pack
  stage clones without an error.
- TRY (`F5`) writes the map aside (`maps/_playtest.json`), loads it and starts
  gameplay; Esc returns to the editor. The map's `loadout` is used when it has
  one, else every weapon the map allows in the vehicle picked beside TRY, on the equip
  screen's starting split of fuel and armour (`Loadout.everything`), so the
  vehicle is as fast as a player's who takes that screen as it comes; an area the map's `equip` closes carries exactly what the map put there. TWO PLAYERS
  beside TRY (always on a map for two) flies it on the split screen
  (`Campaign.start_team`), both players equipped that way. GOD MODE there
  (`app.play_return.god`) starts the vehicle with nothing running out and
  nothing hurting. TRY FROM WHERE THE VIEW IS (`Shift+F5`: under the pointer
  while it is over the map) starts and respawns the vehicle there instead of
  on the home pad (`app.play_return.start`), moved to the nearest free spot
  when something solid stands there (`World:free_spot`); the home pad stays
  the place to fly back to.
- MAP SETTINGS: GENERAL (name, author, players: one or two, one only, two
  only; size), ENVIRONMENT, LOADOUT (the
  player buys and equips, with an optional forced vehicle, the shop open or
  closed, the medals for it, per weapon of the vehicle shown whether it is for
  sale, kept out or owned at a level (a special: to pick or kept out), and each
  of the equip screen's areas left to the player or closed with its content:
  the weapon of every bay, the special or none, the split of fuel and armour;
  or the map sets vehicle, vehicles, ammunition, fuel, armour, weapon levels
  and special),
  DIFFICULTY (the player's own setting, or a preset the map is always played
  on, each value then editable: enemy hit and fire tables, their scales, enemy
  sight, pickup time, the landing rules), OBJECTIVES and BRIEFING (per
  paragraph its text, in a box of several lines where Enter breaks a line and
  a note says how many of the slot's six lines the briefing sets it in, and
  its picture: FROM THE MAP closes the settings for one click on the map and a
  size of 44, 88 or 176 world pixels, with a caption; GAME CARD picks one of
  the pack's cards; PREVIEW THE BRIEFING, also
  `F6`, shows the briefing screen as the player gets it until a key or click).
- OBJECTIVES lists the map's objectives in order: wording (SHOWN AS), OPTIONAL,
  earlier / later, remove. ADD OBJECTIVE: destroy the selected objects, destroy
  enemies of a kind (`goals.kinds` of `data/editor.json`), keep the selected
  objects intact, get to a place (one click on the map, a radius, down or
  stopped there), hold out for a time, collect medals, shoot down helicopters
  (a number; the row says how many posts the map has and whether they send
  another). Objects are taken from
  the selection (USE THE SELECTION; one id per hull and turret) and found
  again with SHOW. TIMED EVENTS beside ADD OBJECTIVE lists the map's timed
  events, each with its time, what it does in a few words, EDIT and remove.
  EVENTS on an objective (not one to keep intact) lists its two events, as it
  comes up and once it is done, with EDIT. EDIT opens the event: AT (seconds
  into the phase, timed events only), a line to SAY and, added with ADD WHAT
  HAPPENS, what it does (`Goals.ACTIONS`): APPEAR and VANISH (anything but a
  start or a mark of the people objectives), BLOW UP (what can be destroyed),
  SET OFF (units on a route), OPEN FIRE and HOLD FIRE (guns and mines), each
  with USE THE SELECTION and SELECT ON MAP; SHELLING (PICK ON THE MAP and a
  radius, drawn on the map in red), TIME LIMIT (seconds, signed), WEATHER, END
  THE PHASE (won or lost). An object that appears wears an eye on the map and
  says so in PROPERTIES. The checks name a timed event at or past the time
  limit, one that says and does nothing, an event that moves a time limit the
  map lacks and one that takes away an object an objective has to destroy. Under the list: IN ORDER, TIME LIMIT, no flight home,
  agents together, commander rule.
- The BASE objects hold START OF PLAYER 1 / 2: a player's chopper with the
  player's number, placed, moved and copied like any object.

Limits: desktop with mouse and keyboard only. The briefing backdrop is the art
set's own, mission number included. A road over the seam does not join a road
on the other side of it. A road has no slanted legs (the centre marks exist level and upright only).
ARRANGE leaves selected roads where they are. Routes and ground lines are not picked by SELECT.

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
  to fire it only between volleys, `first` / `last` for the reload ticks left
  between which it leaves, `volley` within a `cycle`), `reload`
  (+ `reload_random`), and `burst` volleys closed by a `pause`. Burst guns
  speed up with the fire level; missile and shell guns do not.
- Routine 8 (the three-barrel `flakgun` of stage30 / stage31, the briefing's
  "dual ammo" gun) is the one routine that does not follow the original, which
  fires 1 round and 2 side bullets together on every volley (burst 5: 36 / 32 /
  24, then +200 / 100 / 50). Here the middle barrel fires a burst of 3 rounds
  (36 / 32 / 24 apart); after a gap of 64 / 48 / 32 ticks the two outer
  barrels fire 5 pairs of bullets 16 ticks apart, and the next burst follows
  the same gap later (pause +156 / 128 / 104).
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
  (`base_size` in `data/hud.json`). A place a map's objective asks the player
  to get to (`World.marks`, owned by the mission) is a larger white blip
  (`place_size`).
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

- A map is played by two from the map list (2P) or the editor's TRY: a co-op
  run of that one phase (section 6a).
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
  god mode), full weapon lists, no briefing, shop or progression, back to the
  menu after the stats.
- Friendly fire between the players follows the `friendly_fire_pows` option in
  the campaign and in free play (`combat.friendly_fire`, recorded in the replay
  header). Every player weapon then hurts the other players and never its
  shooter (`CombatSystem:_hurt_teammates`): a round striking the vehicle, the
  splash of a hit at half damage, napalm fire, the square blast of a bomb or a
  fused mine, an air strike's impacts. A hit plays the hit effects and sets
  the cause `friendly_fire`. The remote mine hurts every player inside it,
  its owner included, with or without the option.
- Vertical split, camera and HUD per half, shared systems drawn per viewport.
  Same rules as single player via `Mission.for_stage`; either player completes
  any objective. The landing is the whole team's: once the objectives are done,
  every player still flying has to be parked on the home pad
  (`Mission:player_home`), and a half already parked blinks WAIT FOR TEAMMATE. A
  wrecked or out player is not waited for; going down on the way home only wins
  the phase when nobody is left to fly it home. Respawn on the base pad (on a map: the player's start, if it places one); failure
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
  variants; at night they draw the day art dimmed by the variant's
  `night_tint` (`Player.draw_tank_variant`).
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
  (objective cleared), the player hit ricochet and the thunder of a map's
  storm (`weather.thunder`, `kzexp` pitched down).
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
  `mission<M>` (M from `world.env.music`), `game`, else silence (the original
  plays none in play); `ending` for the ending and the credits after it; `hiscores` on
  the high scores after a run (`menu` when browsed from the menu). The pack
  holds `menu.med`, `hiscores.med` and `ending.med` (OctaMED, played through
  ModPlug); an `.ogg` / `.mp3` of the same name replaces one.
- Jingle: `Audio.play_jingle(path)` plays one content file once on the music
  bus, at full level from its first sample (no crossfade), and returns its
  length; `Audio.stop_jingle()` fades it out. With no track playing, music
  requested under a sounding jingle is held until the jingle's last 1.2 s (the
  music fade), so it comes in over the tail. The engine intro card's riff
  (`content/intro/openseek_intro.ogg`).

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
| `night_lighting`, `night_brightness` | VIDEO | Night ambient, headlight beam, explosion, muzzle and fire lights. Off: the original's night, the bare palette and its one spot ahead of the vehicle. |
| `effects_flashes`, `flash_intensity` | VIDEO | Additive flashes, the glow of live fire and screen washes. |
| `postfx_enabled`, `postfx_preset`, `postfx_grade`, `postfx_contrast`, `postfx_sharpen`, `postfx_bloom`, `postfx_vignette`, `postfx_grain`, `postfx_soft_shadows` | EFFECTS | World-view shader (HUD excluded). Presets NONE / MILD / FULL; soft shadows add rotor, smoke and projectile shadows. |
| `speed_scale` | GAMEPLAY | Motion multiplier; animation unscaled. |
| `hud_scale` | GAMEPLAY | HUD size and inset. |
| `axis_aligned_pickups` | GAMEPLAY | Screen-upright pickups and pads, as the original. |
| `friendly_fire_pows` | GAMEPLAY | Player rounds kill POWs and saboteurs and can destroy the player's base buildings (no score, stats or drops); in co-op the players' weapons hurt each other. |
| `score_count_up` | GAMEPLAY | HUD score rolls to new total (frame time, presentation). |
| `shop_fx` | GAMEPLAY | Animated shop medal purse, unaffordable levels greyed with a red COST, sliding focus frame, hover frame, dimmed LOADED under a higher selection (presentation). |
| `style` | STYLE | CLASSIC / ENHANCED / OVERKILL: sets every key the style owns (`data/styles.json`); CUSTOM once one of them differs. `style_chosen` records that the selection screen was confirmed. |
| `difficulty`, `enemy_damage_level`, `enemy_damage`, `enemy_fire_level`, `enemy_fire_rate`, `enemy_aggression`, `pickup_level`, `land_for_medals`, `land_for_supplies` | DIFFICULTY | The original's EASY / MEDIUM / HARD (`game/difficulty`, `data/difficulty.json`), each value also editable (preset then reads CUSTOM); a named preset is re-applied at startup. `enemy_damage_level` (ENEMY DAMAGE) picks the original's per-weapon enemy damage (`enemy_damage` tables in `data/weapons.json`, `Difficulty.damage_level`), `enemy_fire_level` (ENEMY FIRE) its enemy reloads, burst pauses and missile tracking (`data/enemy_weapons.json`, `Difficulty.fire_level`). Extra multipliers, 1.0 in every preset: that damage (DAMAGE SCALE), the enemy fire rate (FIRE SCALE), and aggression (detection and attack range). `pickup_level` (PICKUP TIME: LONG / MEDIUM / SHORT) is how long a power-up lies (17.4 / 13.9 / 10.5 s). MEDIUM needs a landing to collect medals, HARD also fuel and armor. Replay parameters; replays from before them apply HARD with no landing rules (`Replay.LEGACY_PARAMS`). |
| `enemy_hunts_people` | DIFFICULTY | On (the original): guns near a POW or an agent stepping into the open turn on them. Off: the enemy cannot harm people on foot. Outside the presets. |
| `chopper_skin`, `tank_skin` | GAMEPLAY | Solo chopper and tank variants (section 9a); also set by the vehicle select screen. Recorded in the replay header. |
| `coop_lives` | GAMEPLAY | Co-op campaign lives: `separate` or `shared` pool (section 9). |
| `master_volume`, `sfx_volume`, `engine_volume`, `voice_volume`, `ui_volume`, `music_volume` | AUDIO | Master and bus volumes. |
| `audio_positional` | AUDIO | Directional mix; off centres all sounds. |
| `coop_split_pan` | AUDIO | Split-screen stereo bias. |
| `voice_callouts` | AUDIO | Radio callouts. |
| `fullscreen`, `vsync`, `window_size`, `show_fps` | DISPLAY | Window mode, letterboxing. `show_fps` draws the counter in the `chars` font on the HUD's pixel grid, under the score readout. |
| `data/keybinds.json` | CONTROLS | Rebindable gameplay actions. |

Modes and tools: split-screen co-op (free play, campaign and maps), vehicle select
screen (unused `VSELECT` art), replays, chopper skins 2 and 3 (`CHOP*2`,
`CHOP*3`, unused in the original), tank variants from the enemy tanks, runtime
sprite rotation, weather, runtime
shadows, shrapnel / dust / craters, map editor and player-made maps with their records, type editor, vehicle sandbox, asset
galleries, debug mission picker, headless checks.

## 12. Data files

| File | Contents |
|------|----------|
| `data/weapons.json` | Player and enemy weapons: `proj_sprite` (a list picks the first clip the pack has), `enemy_damage` (EASY / MEDIUM / HARD damage to the player when an enemy fires it), levels (`damage` in toughness units, `fire_rate`, `swing_deg`, `range`, flame `angles` / `offsets`), `short`, `icon`, `ammo_max`, `ammo_pickup`, `alternate_side`, `trail`, flame params, `range`, `shadow` (`true` or a share of the flying height), optional `name` (HUD notice; default the key in capitals), `proj_color_missions` (bullet color per mission digit); `air_strike`: target distance, radius, delay, incoming call, marker blink, per level pattern (`strike`, impacts or craft / rounds / lanes, window, impact radius and toughness damage, explosion) and craft visuals. |
| `data/entity_types.json` | Per kind: hit radius, explosion, `armed`, detection / attack radius, `solid`, `collision_radius`, sprite fallbacks, `dead_frame_offset`, `turret_explosion`, `patrol_speed`, `patrol_turn`, `debris`. Flat scalars only (the type editor rewrites it). |
| `data/overrides.json` | Per-sprite fixes over the stage data: `assets` (every stage) and `stages` (one stage), fields `explosion`, `drop`. Empty at present. |
| `data/enemy_weapons.json` | Enemy fire in the original's units (`tick_rate` 70): `turret` (settle, turn, arc), `homing` (bearing refresh per level, radar penalty), the 20 `routines`, `soldier` (with `wander`), `mine`, `helicopter` (with the respawn clearance), `shelling` (the artillery pattern a map's event calls: radius, delay, impacts, window, impact radius, damage to what stands there and per damage level to the players), and `movement` (route modes, hangar rides, yield distance). Read once by `World` (`world.enemy_rules`). |
| `data/missions.json` | Section 9. |
| `data/editor.json` | Map editor: `theme` (colours and sizes of `ui/kit`), `art` (art set labels), `sizes`, `grid_steps`, `categories` and `layers` (kinds per catalog tab, `locked` by default), `layer_colors` (overview map dots), `line_colors` (ground line swatches), `stack_share`, `home_pad` (pad and mark sprite), `names` (sprite labels), `weapons` (labels of enemy weapons), `pickups` (the kinds a map can lay out besides ammunition, and their labels), `cards` (`caption`: colour, shadow, row and the glyphs of the briefing cards' pixel lettering, rows of `#` and `.`), `roads` (width limits, `join` reach, the sprite names of centre marks, and per art set a road's `width`, mark `pitch` and the two `edge` colours), `goals` (ranges and defaults of an objective's radius, seconds, medals, helicopters, of the time limit, a timed event's time, an event's shelling radius and time added; `kinds`: the kind groups an objective may ask for), `difficulty` (ranges of the percentages a map may set), `scatter` / `erase` brush defaults, `ground` (`min_uses`, `clear`), `autosave_seconds`. |
| `data/vehicles/*.json` | Vehicle tuning (sandbox editable); `armor_base` is the original's per-vehicle armor factor (chopper 20, tank 40). Tank only: `bump_bounce`, `bump_back`, `bump_arc`, `bump_min` (the bounce off a solid object). |
| `data/vehicle_variants.json` | Chopper and tank variants (section 9a). |
| `data/credits.json` | Credits: `styles` (fonts, name offset, `color` tint of a mask font) and positioned `entries` (`heading` / `name`, or a label `text`), 320x240 design space. |
| `data/ending.json` | Ending timing (`char_time`, `tab_pause`, `hold`, fades, text `cell`), music track, `anim` (`frame_time`, `cues`: event -> frame list, `loops`: event, level, fade start and length in frames), `extra_lines` (lines appended under a picture, keyed by picture name), `stats` (position, line height, columns, keys per picture, labels) and `preview` (the record and score F11 shows outside a run). |
| `data/animations.json` | Named animation clips. |
| `data/hud.json` | HUD layout; sprite paths through `core/assets`. The `notice` item is the weapon find line: `text` format, `font`, `time`, `fade_in`, `fade_out`. `icon_color_mission` tints a mask icon per mission digit (the player label on the night HUD). `reversed_sets` on a gauge lists the missions whose own sprite set runs from full to empty (the armour gauge of mission 2, `STAGE02/ARMOUR.BIN`); the HUD turns such a set round on load. |
| `data/audio.json` | Sound events (`defaults`, `events` with clip or `clips`, per-vehicle variants, `size_pitch`, `group`), `callouts` (armor / fuel thresholds, warning period, selection guard, finish-him mark, follow-up lines) and `sequences` (timed screen cues). |
| `data/photo.json` | Photo mode (`--photo`): `outputs` (label, `w`, `h`; an entry without a size is the window), zoom limits and wheel step, turn step (degrees) and drag rate (degrees per pixel), slow motion speed. |
| `data/lightfx.json` | `night` per mission digit (or `default`, which a map's night over a day art set uses): `ambient` floor colour, `max_light` cap, `headlight` (`color`, `gap` of the lamp ahead of the vehicle centre, beam `length` in world units, `spread_deg` half-angle and `intensity`, `pool_radius` / `pool_ahead` / `pool_intensity` of the pool around the vehicle). `weapons` (a round in flight) and `effects` (an ignited effect clip) carry a light: `radius`, `intensity` and `color` in the night light map, `flicker` depth, `fade` over the round's range, `glow` and `glow_radius` of the additive glow shown on any stage. Intensities are multiples of the art's brightness. |
| `data/postfx.json` | `look` (100% values), `missions` (per mission digit, look fields that differ, e.g. the cold grade of mission 1) and `presets`. |
| `data/weather.json` | Weather presets by name. Particles: `area` (art pixels per particle), `wind` (world px/s), `speed` (per-particle factor range), `sway` / `sway_hz`, `size`, `large` (share one art pixel bigger), `streak` (trail in art pixels along the wind), `color`, `alpha`. Optional `gust` (`strength` of the wind's swing, `period` s), `haze` (`color`, flat `alpha`, `gust` alpha swing, `night` factor on a night stage, `banks`: noise layers with `alpha`, `scale` in world px per texel, `drift` as a share of the wind) and `lightning` (`interval`, `flickers`, `gap`, `duration`, `strength`, `color`, `wash` of the day flash, `night` light map lift, `thunder` event, its `delay` from near to far). |
| `data/difficulty.json` | EASY / MEDIUM / HARD presets: values for each difficulty key. |
| `data/styles.json` | `styles` (`name`, `label`, `about`: the one line shown under the cards, `camo`: the VSELECT camo row behind the card, `values` per owned Config key), `default` (the style the selection screen starts on) and `preview`: `fade` (ticks of fade in and out around a run) and `runs`, each a `stage`, a `vehicle`, a start `x`, `y`, `angle` and a `script` of segments (`ticks`, `held` actions, `events` on the first tick). |
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
| `assets/ending/ending.json`, `assets/ending/reganim.flc` | Ending: `prompt` and `slides` (`picture`, `lines` of `{text, x, y}` with tabs, VIC3 `alternate_lines`, `prompt` position); the CD's animation. The shareware gets the same file with its four DEMO slides, no animation. |
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
`openseek-<id>-win64.zip`, with `--macos SETUP` `openseek-<id>-macos.zip`,
with `--linux` `openseek-<id>-linux.tar.gz` (the `.love`, the zipapp and an
`openseek` launcher for the LOVE of the system).
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
| `export_love2d.py all` | `assets/stageMP.json`, `assets/stageMP/` for the missions present, in the mission's in-game palette `PAL1.BIN` (`gamedata.stage_palette_path`, as every gameplay export; `PAL.BIN` holds magenta markers some sprites draw). Classes no entity uses are rendered too when their BIN is in their own `STAGE0N/` (the crater, wreckage, the fuel dump: the editor's spare entries). `BORROWED`: sheets no class points at get a copy of a donor class of their mission on every stage of it, with `borrowed` naming the donor and no `raw`; no entity places them. `CLEAR_INDICES`: per-sprite palette indices exported transparent, the sand dune's black crest |
| `export_fullscreen.py` | `assets/fullscreen/`: every fullscreen BIN (`NAME.png`, `STAGE0N_NAME.png`) in its own palette |
| `export_projectiles.py` | `assets/stage00/` projectiles; the crater `hole_f16.png` per mission into `assets/stage{M}0/` (STAGE00's HOLE4038 in the palette of missions 2 to 4, which have none of their own) |
| `export_player.py` | `assets/player/`, plus `VARIANT_SPRITES` (the DESERT 2 turret in the day palette) |
| `export_hud.py` | `assets/hud/` |
| `export_animations.py` | `assets/effects/` |
| `export_fonts.py` | `assets/fonts/` (`overkill0`..`overkill4`: one OVERKILL banner per mission in its in-game palette; `chars3`: the night mission's own green CHARS in its `PAL1.BIN`; `credchars`: HICHARS in the CREDITS palette) |
| `export_mainmen.py` | `assets/mainmen/` (words, generated arrow cursor), `assets/mainmen/font/`, `assets/fonts/mainmen.*`, `assets/fonts/main.*` (plus `content/fonts/main_synth/`); runtime menu palette in `MENU_PALETTE` |
| `export_screens.py` | CREDANIM / HIANIM (CREDITS / HISCORE palette, fixed frame box via `menutitle.py`), POWCOUNT, OKBADGE, KILLICON, BURN, PHASE cards (in the palette of the briefing picture `MS.BIN` they are shown on) |
| `export_mission.py` | `assets/mission/` |
| `export_mission_text.py` | `assets/mission_text.json` |
| `export_sounds.py` | `assets/sounds/`, `assets/sounds.json` |
| `export_phend.py` | `assets/phend/` |
| `export_shop.py` | `assets/pow/` sprites, `assets/pow/weapon_info.json` (WINF / WINFT prices and descriptions), `assets/fonts/charspow.*`, all in the `POWUP.BIN` palette (disabled buttons grey out 224 / 215; run after `export_fonts.py`) |
| `export_equip.py` | `assets/equip/` in the `EQPCHP.BIN` palette, `layout.json` template-matched on the backdrop index maps |
| `export_music.py` | `assets/music/menu.med`, `hiscores.med`, `ending.med`: `SEEKMOD.BIN`, `SEEKHMOD.BIN`, `SEEKEMOD.BIN` as they are |
| `export_ending.py` | `assets/ending/ending.json` (story text read from `SEEK.EXE` at the registered or shareware release's addresses, layout from its code; the shareware's register pitch and screenshots are not exported), `reganim.flc` (CD release), `assets/fonts/endstory.*` (ENDCHARS in the FIN01 palette, DEMO01 for the shareware, with its drop shadow) |
| `decode_level.py` | Stage BIN -> JSON (`--summary`) |
| `decode_blitter.py` | Exact world-sprite decoder |
| `decode_planar.py` | Exact planar HUD sprite decoder |
| `unjam.py` | `DATA.JAM` / `DATA.JAL` lister and extractor |
| `gen_editor_icons.py` | `content/editor/icons/`: the map editor's icons, white on alpha at 16, 20, 32 and 40 px, from the SVGs vendored under `svg/` (needs `rsvg-convert`) |
| `decode_palette.py`, `decode_sincos.py`, `decode_stage_assets.py`, `decode_font.py`, `decode_fullscreen.py`, `decode_fullscreen_v2.py` | Viewers / dumps (need Pillow, numpy) |

## 14. Controls

| Key | Action |
|-----|--------|
| WASD / arrows | Drive |
| Shift + turn | Strafe chopper / rotate tank turret |
| Ctrl | Fire |
| Space | Take off / land |
| Q, 1-9 | Cycle / select weapon |
| E | Weapon level (free play, `--dev`) |
| P | Pause |
| R | Restart stage (free play; in a campaign only under `--dev`) |
| F2 | Debug inspector (`--dev`) |
| F5 | God mode (`--dev`) |
| F6 | Fly-over pickup override (ignores the difficulty landing rules; `--dev`) |
| Delete | Free play: wreck the own vehicle (crash picture test; `--dev`) |
| PgUp / PgDn | Free play: the pack stage before / after (`--dev`) |
| F9 | Radar auto zoom (in game, rebindable). Co-op: P1 Tab, P2 keypad `.` |
| F12 | Screenshot (rebindable) |
| T | Replay playback: show / hide the REPLAY tick counter (hidden by default, always shown under `--verify`) |
| Main menu, `--dev` | `F1` fly the loaded stage, `F3` sandbox, `F4` replay panel, `F7` co-op free play, `F8` / `F9` / `F10` animation / font / sound gallery, `F11` ending (`Shift`: VIC3's alternate ending), `Delete` game-over picture (`Shift`: the one before a respawn) |
| Map list | Up / Down, Enter play, `E` edit, `N` new, `C` copy, `Delete` twice erase, `F` folder, Esc back |
| Map editor | Tools `V` `P` `B` `E` `R` `L` `O` `U`; wheel zoom; right or middle drag, Space + drag, `W A S D` move the view; arrows nudge (Shift 8 px); `Ctrl+C` / `X` / `V` / `D` copy, cut, paste, duplicate; `Delete`; `Ctrl+Z` / `Ctrl+Y` (or `Ctrl+Shift+Z`) undo / redo; `Ctrl+S` save, `Ctrl+Shift+S` save as, `Ctrl+N`, `Ctrl+O`; `Ctrl+A` select all; `Ctrl+Shift+G` ungroup; `Ctrl+[` / `Ctrl+]` turn the selection a quarter (and lay its sprites across), `Shift+H` / `Shift+V` mirror it; `G` grid, `Ctrl+G` snap; Ctrl while drawing or dragging constrains (45 degree steps, one axis); `Tab` single parts; `Home` home pad; `F` show the selection; `M` overview map; `+` / `-` zoom, `0` reset the zoom, `Shift+0` show the whole map; `F5` try, `Shift+F5` try from the pointer or the view; `F6` briefing preview; `F1` keys; Esc cancel, then leave |
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
