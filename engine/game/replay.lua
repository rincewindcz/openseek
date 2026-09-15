local Class      = require "engine.core.class"
local InputFrame = require "engine.core.input_frame"

-- Recorded run: the header describing the starting conditions, the per-tick input
-- frames, and periodic state checksums. Input only, no state snapshots, so a file
-- is small and is exactly what a network peer would have to exchange for lockstep
-- play.
--
-- File format (text, one record per line):
--
--   OSREPLAY 2
--   key=value            header lines: build, stage, mode, seed, params, players
--   --                   end of header
--   i <tick> <slot> <mask>[:<turn>] [event,event]
--   c <tick> <hash> <players> <entities> <misc>
--
-- turn is the analog turn step (InputFrame.TURN_STEPS); a line without it is
-- digital. Input lines are delta encoded: one is written only when a slot's held
-- mask or turn changes or the tick carries an edge event, so a quiet minute costs a handful of
-- lines. A tick with no line repeats the previous mask with no events.
local Replay = Class()

Replay.FORMAT = 2
Replay.DIR    = "replays"

-- Config keys that change the simulation. They are stored in the header and
-- re-applied during playback, and held to the recorded values while a run is
-- being recorded, so a mid-run options edit cannot desync a replay.
Replay.PARAMS = { "speed_scale", "explosive_trees", "tree_crush_speed", "friendly_fire_pows" }

-- A replay is only valid for the build that produced it: platform libm
-- differences can change the last bit of a sine, which compounds over a run.
function Replay.build_id()
    local major, minor, revision = love.getVersion()
    return string.format("love%d.%d.%d-%s-%s", major, minor, revision,
        love.system.getOS(), jit and jit.version or _VERSION)
end

function Replay:init(header)
    self.header  = header or {}
    self.inputs  = {}    -- slot -> ordered list of {tick, mask, events}
    self.checks  = {}    -- ordered list of {tick, hash, players, entities, misc}
    self.length  = 0     -- last recorded tick
    self._last   = {}    -- slot -> last recorded frame, for delta encoding
    self._cursor = {}    -- slot -> playback position in inputs[slot]
    self._check_at = 1   -- playback position in checks
end

-- recording

function Replay:record_input(tick, slot, frame)
    local last = self._last[slot]
    if last and last.mask == frame.mask and last.turn == frame.turn and #frame.events == 0 then
        return
    end
    local list = self.inputs[slot] or {}
    self.inputs[slot] = list
    list[#list + 1] = { tick = tick, mask = frame.mask, turn = frame.turn, events = frame.events }
    self._last[slot] = frame
    if tick > self.length then self.length = tick end
end

-- parts is a Replay.checksum_parts table; the components travel with the combined
-- hash so playback can say which part of the state diverged.
function Replay:record_check(tick, parts)
    if type(parts) == "number" then parts = { all = parts } end
    self.checks[#self.checks + 1] = {
        tick = tick, hash = parts.all,
        players = parts.players, entities = parts.entities, misc = parts.misc,
    }
    if tick > self.length then self.length = tick end
end

-- playback

function Replay:rewind()
    self._cursor   = {}
    self._check_at = 1
end

-- The frame for a tick: the last input line at or before it, with its events only
-- on the exact tick they were recorded (edge actions fire once).
function Replay:frame_for(tick, slot)
    local list = self.inputs[slot]
    if not list then return InputFrame.EMPTY end
    local i = self._cursor[slot] or 0
    if i > 0 and list[i].tick > tick then i = 0 end   -- rewound: rescan from the start
    while list[i + 1] and list[i + 1].tick <= tick do i = i + 1 end
    self._cursor[slot] = i
    local record = list[i]
    if not record then return InputFrame.EMPTY end
    if record.tick == tick then return InputFrame.new(record.mask, record.events, record.turn) end
    return InputFrame.new(record.mask, {}, record.turn)
end

-- The recorded checkpoint for a tick, or nil when that tick was not checkpointed.
function Replay:check_for(tick)
    local entry = self.checks[self._check_at]
    while entry and entry.tick < tick do
        self._check_at = self._check_at + 1
        entry = self.checks[self._check_at]
    end
    if entry and entry.tick == tick then return entry end
    return nil
end

-- Which components of a checkpoint disagree with the live state, as a list of
-- names ("player", "entities", "projectiles/rng"); empty when they all match.
function Replay.check_diff(entry, parts)
    local out = {}
    if entry.players  and entry.players  ~= parts.players  then out[#out + 1] = "player" end
    if entry.entities and entry.entities ~= parts.entities then out[#out + 1] = "entities" end
    if entry.misc     and entry.misc     ~= parts.misc     then out[#out + 1] = "projectiles/rng" end
    return out
end

-- checksum

-- Fold a string into a running hash. Kept inside double precision (the largest
-- intermediate is 31 * 2^31, well under 2^53) so it is exact everywhere Lua runs.
local function fold(hash, s)
    for i = 1, #s do
        hash = (hash * 31 + s:byte(i)) % 2147483647
    end
    return hash
end

-- The simulation state as three hashes plus their combination: player kinematics
-- and resources, every entity's health and state, and the rest (live projectile
-- count, random numbers drawn, the simulation clock). "%.17g" round-trips a double
-- exactly, so a difference of one bit is caught. Splitting them lets a divergence
-- report name the part that moved instead of only the tick.
function Replay.checksum_parts(world, players, combat)
    local ph = 5381
    for _, p in ipairs(players or {}) do
        ph = fold(ph, string.format("%.17g;%.17g;%.17g;%.17g;%.17g;%d;%d|",
            p.x, p.y, p.angle, p.armor or 0, p.fuel or 0, p.lives or 0, p.pows or 0))
    end
    local eh = 5381
    for _, e in ipairs(world.entities) do
        eh = fold(eh, string.format("%.17g;%s|", e.hp or 0, e.state or ""))
    end
    local mh = fold(5381, string.format("%d;%d;%.17g",
        #((combat and combat.projectiles) or {}), world.rng.draws, world.time))
    local all = fold(fold(fold(5381, tostring(ph)), tostring(eh)), tostring(mh))
    return { all = all, players = ph, entities = eh, misc = mh }
end

function Replay.checksum(world, players, combat)
    return Replay.checksum_parts(world, players, combat).all
end

-- serialization

local function encode_events(events)
    if #events == 0 then return "" end
    return " " .. table.concat(events, ",")
end

function Replay:serialize()
    local out = { "OSREPLAY " .. Replay.FORMAT }
    local keys = {}
    for k in pairs(self.header) do keys[#keys + 1] = k end
    table.sort(keys)   -- stable file order, so two recordings diff cleanly
    for _, k in ipairs(keys) do
        out[#out + 1] = k .. "=" .. tostring(self.header[k])
    end
    out[#out + 1] = "--"
    -- Interleave the slots by tick so the body reads in play order.
    local merged = {}
    for slot, list in pairs(self.inputs) do
        for _, r in ipairs(list) do
            merged[#merged + 1] = { tick = r.tick, slot = slot, mask = r.mask, turn = r.turn, events = r.events }
        end
    end
    table.sort(merged, function(a, b)
        if a.tick ~= b.tick then return a.tick < b.tick end
        return a.slot < b.slot
    end)
    for _, r in ipairs(merged) do
        local turn = r.turn and (":" .. r.turn) or ""
        out[#out + 1] = string.format("i %d %d %d%s%s", r.tick, r.slot, r.mask, turn, encode_events(r.events))
    end
    for _, c in ipairs(self.checks) do
        out[#out + 1] = string.format("c %d %d %d %d %d", c.tick, c.hash,
            c.players or 0, c.entities or 0, c.misc or 0)
    end
    return table.concat(out, "\n") .. "\n"
end

local function parse(text)
    local replay = Replay:new({})
    local in_body = false
    for line in text:gmatch("[^\n]+") do
        if line == "--" then
            in_body = true
        elseif not in_body then
            local k, v = line:match("^([%w_.]+)=(.*)$")
            if k then replay.header[k] = v end
        else
            local kind, rest = line:match("^(%a) (.+)$")
            if kind == "i" then
                local tick, slot, mask, turn, events = rest:match("^(%d+) (%d+) (%d+):?(%-?%d*)%s*(.*)$")
                if tick then
                    local list = {}
                    for e in (events or ""):gmatch("[^,]+") do list[#list + 1] = e end
                    local s = tonumber(slot)
                    replay.inputs[s] = replay.inputs[s] or {}
                    local into = replay.inputs[s]
                    into[#into + 1] = {
                        tick = tonumber(tick), mask = tonumber(mask), turn = tonumber(turn), events = list,
                    }
                    if tonumber(tick) > replay.length then replay.length = tonumber(tick) end
                end
            elseif kind == "c" then
                -- "c tick hash [players entities misc]": the component hashes are
                -- optional so a file written before they existed still loads.
                local nums = {}
                for n in rest:gmatch("%-?%d+") do nums[#nums + 1] = tonumber(n) end
                if nums[1] and nums[2] then
                    replay.checks[#replay.checks + 1] = {
                        tick = nums[1], hash = nums[2],
                        players = nums[3], entities = nums[4], misc = nums[5],
                    }
                    if nums[1] > replay.length then replay.length = nums[1] end
                end
            end
        end
    end
    return replay
end

-- files

function Replay.path_for(stage)
    return string.format("%s/%s-%s.osr", Replay.DIR, stage or "stage",
        os.date("%Y%m%d-%H%M%S"))
end

function Replay:save(path)
    path = path or Replay.path_for(self.header.stage)
    love.filesystem.createDirectory(Replay.DIR)
    local ok = love.filesystem.write(path, self:serialize())
    return ok and path or nil
end

function Replay.load(path)
    local text = love.filesystem.getInfo(path) and love.filesystem.read(path)
    if not text then return nil, "cannot read " .. path end
    if not text:match("^OSREPLAY ") then return nil, "not a replay: " .. path end
    local replay = parse(text)
    replay.path = path
    return replay
end

-- Recorded files, newest first, with their headers loaded for the picker.
function Replay.list()
    local out = {}
    if not love.filesystem.getInfo(Replay.DIR) then return out end
    for _, name in ipairs(love.filesystem.getDirectoryItems(Replay.DIR)) do
        if name:match("%.osr$") then
            local path = Replay.DIR .. "/" .. name
            local replay = Replay.load(path)
            if replay then
                out[#out + 1] = { path = path, name = name, replay = replay }
            end
        end
    end
    table.sort(out, function(a, b) return a.name > b.name end)
    return out
end

function Replay:delete()
    if self.path then love.filesystem.remove(self.path) end
end

-- simulation parameters

-- The current values of the simulation-affecting Config keys.
function Replay.params_now()
    local Config = require "engine.core.config"
    local out = {}
    for _, key in ipairs(Replay.PARAMS) do out[key] = Config[key] end
    return out
end

-- Force Config back to a recorded set of parameters. Applied every tick of a
-- recorded or replayed run, so editing them from the options screen mid-run
-- cannot silently change the simulation the recording claims to describe.
function Replay.apply_params(params)
    local Config = require "engine.core.config"
    for _, key in ipairs(Replay.PARAMS) do
        local v = params[key]
        if v ~= nil then
            if type(Config[key]) == "boolean" then
                Config[key] = (v == true or v == "true")
            elseif type(Config[key]) == "number" then
                Config[key] = tonumber(v) or Config[key]
            else
                Config[key] = v
            end
        end
    end
end

-- header helpers

function Replay:number(key, default)
    return tonumber(self.header[key]) or default
end

function Replay:boolean(key)
    return self.header[key] == "true"
end

-- "a:1,b:2" -> { a = 1, b = 2 }; values stay strings unless numeric.
function Replay.decode_map(text)
    local out = {}
    for pair in (text or ""):gmatch("[^,]+") do
        local k, v = pair:match("^(.-):(.*)$")
        if k then out[k] = tonumber(v) or v end
    end
    return out
end

function Replay.encode_map(map)
    local keys = {}
    for k in pairs(map or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. ":" .. tostring(map[k]) end
    return table.concat(parts, ",")
end

function Replay.encode_list(list)
    return table.concat(list or {}, ",")
end

function Replay.decode_list(text)
    local out = {}
    for item in (text or ""):gmatch("[^,]+") do out[#out + 1] = item end
    return out
end

return Replay
