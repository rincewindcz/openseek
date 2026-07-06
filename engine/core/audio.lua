local json = require "lib.json"

-- Minimal sound manager. Loads the catalog exported by tools/export_sounds.py
-- (data/sounds.json: ordered categories of {name, file, label, rate}) and plays
-- clips by name. Sources are created lazily and cached, so a repeated clip
-- retriggers from the start. Missing catalog is a no-op so the app still runs
-- before the sounds have been exported.
local Audio = {
    _cats    = {},   -- ordered categories for the gallery
    _files   = {},   -- name -> asset path
    _sources = {},   -- name -> love.audio.Source (lazy)
    _last    = nil,  -- name of the most recently played clip
}

function Audio.load(path)
    Audio._cats, Audio._files, Audio._sources, Audio._last = {}, {}, {}, nil
    local raw = love.filesystem.read(path)
    if not raw then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return end
    Audio._cats = data
    for _, cat in ipairs(data) do
        for _, item in ipairs(cat.items or {}) do
            Audio._files[item.name] = item.file
        end
    end
end

-- Ordered list of { name, title, items = {{name, label, file}, ...} }.
function Audio.categories()
    return Audio._cats
end

function Audio.play(name)
    local file = Audio._files[name]
    if not file then return end
    local src = Audio._sources[name]
    if not src then
        local ok, s = pcall(love.audio.newSource, file, "static")
        if not ok then return end
        src = s
        Audio._sources[name] = src
    end
    src:stop()
    src:play()
    Audio._last = name
end

function Audio.last_played()
    return Audio._last
end

-- True while the named clip's source is still sounding.
function Audio.is_playing(name)
    local src = Audio._sources[name]
    return src ~= nil and src:isPlaying()
end

function Audio.stop(name)
    local src = Audio._sources[name]
    if src then src:stop() end
    if Audio._last == name then Audio._last = nil end
end

function Audio.stop_all()
    for _, src in pairs(Audio._sources) do src:stop() end
    Audio._last = nil
end

return Audio
