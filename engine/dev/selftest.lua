local Replay     = require "engine.game.replay"
local InputFrame = require "engine.core.input_frame"

-- Determinism self-test: drives a scripted phase three ways and compares the
-- simulation state tick by tick, reporting the first tick that differs and which
-- part of the state moved.
--
--   1. the same script twice          - is the simulation itself deterministic
--   2. record the script, replay it   - is the recorder faithful
--   3. the same, pausing part way     - does pausing move the simulation clock
--
-- Case 1 bypasses recording, so a failure there separates "the simulation is not
-- deterministic" from "the recorder is wrong". Run it from the repo root:
--
--   love . --selftest              (600 ticks, about 10 s of play)
--   love . --selftest 3600 stage12
--
-- See DETERMINISM.md.
local Selftest = {}

local TICK     = 1 / 60
local PAUSE_AT = 0.5   -- fraction of the run at which the pause case pauses

-- A scripted run that exercises the systems a quiet run would not: thrust, turns
-- both ways, sustained fire, weapon changes, and a landing attempt.
local function script_mask(tick)
    local mask = InputFrame.BIT.up
    local phase = math.floor(tick / 120) % 4
    if phase == 1 then mask = mask + InputFrame.BIT.left end
    if phase == 3 then mask = mask + InputFrame.BIT.right end
    if tick > 60 then mask = mask + InputFrame.BIT.fire end
    return mask
end

local function build_script(stage, ticks)
    local script = Replay:new({
        stage = stage, mode = "single", seed = 20260801, players = 1,
        death = "false", easy_pickups = "false", friendly_fire = "false",
    })
    for tick = 1, ticks do
        local events = {}
        if tick % 420 == 0 then events[#events + 1] = "weapon" end
        script:record_input(tick, 1, InputFrame.new(script_mask(tick), events))
    end
    script.length = ticks + 10   -- never finishes on its own; the harness stops it
    return script
end

-- The state fingerprint, split so a divergence names the part that moved.
local function sample(app, scene)
    local p = scene.player
    if not p then return nil end   -- the scene handed off mid-tick
    local players = { p }
    local world   = app.world
    local ent_hp, ent_state = 0, 0
    for i, e in ipairs(world.entities) do
        ent_hp = (ent_hp + (e.hp or 0) * i) % 2147483647
        ent_state = (ent_state + #tostring(e.state or "") * i) % 2147483647
    end
    return {
        all    = Replay.checksum(world, players, app.combat),
        px     = p.x, py = p.y, angle = p.angle,
        armor  = p.armor, fuel = p.fuel,
        ent_hp = ent_hp, ent_state = ent_state,
        proj   = #app.combat.projectiles,
        helis  = #(world.air_units or {}),
        draws  = world.rng.draws,
        fx     = #app.combat.effects,
    }
end

-- Input source that answers straight from the script, so a pass can be recorded
-- exactly as a live keyboard run would be.
local function script_source()
    local src = {}
    function src:queue(_event) end
    function src:frame(tick)
        local events = {}
        if tick % 420 == 0 then events[#events + 1] = "weapon" end
        return InputFrame.new(script_mask(tick), events)
    end
    return src
end

-- Drive a scene until it has simulated `ticks` ticks, sampling each one. Samples
-- are keyed by the simulation tick, not by the number of updates dispatched, so a
-- run that skips updates (paused) lines up with one that does not. hook runs after
-- each dispatch and can poke the scene (that is how the pause case is exercised).
local function drive(app, scene, ticks, hook)
    local samples = {}
    local dispatches = 0
    scene._pause_at = math.floor(ticks * PAUSE_AT)
    while #samples < ticks and dispatches < ticks * 3 do
        if app.scenes:top() ~= scene then break end
        dispatches = dispatches + 1
        local before = app.tick
        app.scenes:dispatch("update", TICK)
        if app.tick > before then
            local s = sample(app, scene)
            if not s then break end   -- scene handed off (mission over, playback ended)
            samples[app.tick] = s
        end
        if hook then hook(scene, app.tick, dispatches) end
    end
    return samples
end

local function run_pass(app, script, ticks)
    app.replay_play   = script
    app.replay_verify = false
    app.replay_result = nil
    script:rewind()
    app.scenes:switch("gameplay")
    local samples = drive(app, app.scenes:top(), ticks)
    app.scenes:switch("overview")
    return samples
end

-- Live pass: the scripted input goes through the recorder exactly as keyboard
-- input would, and the recording it produces is returned for playback.
local function record_pass(app, stage, ticks, hook)
    app.replay_play = nil
    app.record_runs = true
    if app.world.stage_name ~= stage then
        app.world:load(stage)
        app.after_stage_load()
    end
    app.scenes:switch("gameplay")
    local scene = app.scenes:top()
    scene.sources[1] = script_source()
    scene.source     = scene.sources[1]
    local samples = drive(app, scene, ticks, hook)
    local recording = scene.recording
    scene.recording = nil          -- keep the self-test from writing a file
    app.scenes:switch("overview")
    return samples, recording
end

-- What a player does that a script does not: pause for a while and carry on.
-- Pausing must not move the simulation clock, or every tick after it lands in the
-- recording under the wrong number and the replay desyncs from there.
local function pause_hook(scene, tick, _dispatches)
    if tick == scene._pause_at then scene.paused = true end
    if scene.paused then
        scene._pause_left = (scene._pause_left or 45) - 1
        if scene._pause_left <= 0 then scene.paused = false end
    end
end

local FIELDS = { "px", "py", "angle", "armor", "fuel",
                 "ent_hp", "ent_state", "proj", "helis", "draws", "fx" }

-- Compare two runs tick by tick, naming the first tick that differs and which
-- part of the state moved.
local function compare(label, a_run, b_run)
    local n = math.min(#a_run, #b_run)
    for i = 1, n do
        local a, b = a_run[i], b_run[i]
        if a.all ~= b.all then
            print(("%s: DIVERGED at tick %d (%.1f s)"):format(label, i, i / 60))
            for _, field in ipairs(FIELDS) do
                if a[field] ~= b[field] then
                    print(("  %-9s %s  ->  %s"):format(field, tostring(a[field]), tostring(b[field])))
                end
            end
            return false
        end
    end
    if #a_run ~= #b_run then
        print(("%s: DIVERGED, run lengths differ (%d vs %d)"):format(label, #a_run, #b_run))
        return false
    end
    print(("%s: OK, %d ticks identical"):format(label, n))
    return true
end

function Selftest.run(app, ticks, stage)
    ticks = ticks or 600
    stage = stage or app.world.stage_name
    -- The passes run far faster than real time, so nothing should sound.
    app.audio_mute = true
    if app.sound then app.sound:set_muted(true) end
    print(("selftest: %s, %d ticks per case"):format(stage, ticks))
    local script = build_script(stage, ticks)

    local ok = true

    -- 1: the simulation itself, driven twice from the same scripted frames.
    local first  = run_pass(app, script, ticks)
    local second = run_pass(app, script, ticks)
    ok = compare("simulation", first, second) and ok

    -- 2: the whole recorder path, which is what a player actually exercises:
    -- record a run, then replay the file it produced.
    local live, recording = record_pass(app, stage, ticks)
    if not recording then
        print("FAIL: the run produced no recording")
        return false
    end
    print(("recorded %d input lines, %d checkpoints, length %d"):format(
        #(recording.inputs[1] or {}), #recording.checks, recording.length))
    recording.length = ticks + 10   -- the harness decides when to stop
    local played = run_pass(app, recording, ticks)
    ok = compare("record -> replay", live, played) and ok

    -- 3: the same, through a run that pauses part way.
    local paused_live, paused_rec = record_pass(app, stage, ticks, pause_hook)
    if not paused_rec then
        print("FAIL: the paused run produced no recording")
        return false
    end
    paused_rec.length = ticks + 10
    local paused_played = run_pass(app, paused_rec, ticks)
    ok = compare("record -> replay (with a pause)", paused_live, paused_played) and ok

    return ok
end

return Selftest
