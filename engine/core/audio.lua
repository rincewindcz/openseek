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

-- 1-based index of the category currently holding the named clip, or nil.
function Audio.category_of(name)
    for ci, cat in ipairs(Audio._cats) do
        for _, item in ipairs(cat.items or {}) do
            if item.name == name then return ci end
        end
    end
end

-- Move the named clip into the category at target_index (1-based). Returns true
-- when the clip moved; false if it is missing, already there, or the index is
-- out of range. The gallery re-layouts and can persist with Audio.save.
function Audio.move(name, target_index)
    local target = Audio._cats[target_index]
    if not target then return false end
    for _, cat in ipairs(Audio._cats) do
        for i, item in ipairs(cat.items or {}) do
            if item.name == name then
                if cat == target then return false end
                table.remove(cat.items, i)
                target.items = target.items or {}
                target.items[#target.items + 1] = item
                return true
            end
        end
    end
    return false
end

local function json_string(s)
    return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                      ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
end

-- Persist the current categorization back to data/sounds.json, preserving the
-- exported shape (ordered categories of {name, title, items:[{name,file,label,
-- rate}]}). Returns true on success.
function Audio.save(path)
    local out = { "[" }
    local cats = Audio._cats
    for ci, cat in ipairs(cats) do
        out[#out + 1] = "  {"
        out[#out + 1] = '    "name": '  .. json_string(cat.name)  .. ","
        out[#out + 1] = '    "title": ' .. json_string(cat.title) .. ","
        out[#out + 1] = '    "items": ['
        local items = cat.items or {}
        for ii, it in ipairs(items) do
            local parts = {
                '"name": '  .. json_string(it.name),
                '"file": '  .. json_string(it.file),
                '"label": ' .. json_string(it.label),
            }
            if it.rate ~= nil then parts[#parts + 1] = '"rate": ' .. tostring(it.rate) end
            out[#out + 1] = "      { " .. table.concat(parts, ", ") .. " }"
                .. (ii < #items and "," or "")
        end
        out[#out + 1] = "    ]"
        out[#out + 1] = "  }" .. (ci < #cats and "," or "")
    end
    out[#out + 1] = "]"

    local full = love.filesystem.getSource() .. "/" .. path
    local f = io.open(full, "w")
    if not f then return false end
    f:write(table.concat(out, "\n") .. "\n")
    f:close()
    return true
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
