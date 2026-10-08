-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Asset path resolution across the engine's two asset roots.
--
--   content/...       engine-owned artwork, tracked in git and shipped with the
--                     engine. Original work, no bytes from the original game.
--   everything else   the pack decoded from the user's own copy of the game by
--                     tools/ (assets/), which is not distributable.
--
-- Data-driven paths (data/hud.json, data/animations.json, ...) name the root
-- explicitly, so a path's provenance is readable where it is declared:
--
--   "content/hud/player_f00.png"   shipped
--   "hud/armour_f00.png"           from the pack
--
-- Loaders take the JSON path and go through Assets.path / Assets.exists rather
-- than concatenating "assets/" themselves.
--
-- tools/build_pack.py writes the pack with a manifest.json (schema, edition,
-- missions). Release builds convert into the save directory, which LOVE
-- searches before the source, so the same "assets/..." paths resolve there.
-- A pack without a manifest is a developer pack exported by hand and is
-- accepted as is.

local json = require "lib.json"

local Assets = {}

-- Bump together with PACK_SCHEMA in tools/build_pack.py whenever the exporters
-- change what the engine reads; an older pack is then rebuilt.
Assets.SCHEMA = 6

local PACK     = "assets/"
local CONTENT  = "content/"
local MANIFEST = PACK .. "manifest.json"

-- Pack files the boot path cannot run without.
local REQUIRED = {
    "stage00.json",
    "fonts/chars.json",
    "fullscreen/TITLE.png",
    "sounds.json",
    "mission_text.json",
}

function Assets.path(p)
    if p:sub(1, #CONTENT) == CONTENT then return p end
    return PACK .. p
end

function Assets.exists(p)
    return love.filesystem.getInfo(Assets.path(p)) ~= nil
end

-- The pack manifest, or nil for a developer pack without one.
function Assets.manifest()
    if not love.filesystem.getInfo(MANIFEST) then return nil end
    local ok, manifest = pcall(json.decode, love.filesystem.read(MANIFEST) or "")
    return ok and type(manifest) == "table" and manifest or nil
end

-- "ok", "missing" (no usable pack) or "outdated" (built for an older schema).
function Assets.pack_status()
    for _, p in ipairs(REQUIRED) do
        if not Assets.exists(p) then return "missing" end
    end
    local manifest = Assets.manifest()
    if manifest and manifest.schema ~= Assets.SCHEMA then return "outdated" end
    return "ok"
end

return Assets
