-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Font = require "engine.core.font"
local json = require "lib.json"

-- What this build is. A packaged game carries build.json, written by
-- tools/build_release.py: `version` (the release tag, absent on a build made
-- between releases), `commit` (short hash) and `dirty` (built with uncommitted
-- changes). A source checkout has no build.json and is a development build.
local Version = {}

local BUILD_PATH   = "build.json"
local TAG_FONT     = "chars"
local COMMIT_FONT  = "keysfont"
local COMMIT_COLOR = { 0.6, 0.6, 0.6 }
local MARGIN_X     = 4
local MARGIN_Y     = 3
local LINE_GAP     = 2

local build

function Version.build()
    if not build then
        local ok, decoded = pcall(json.decode, love.filesystem.read(BUILD_PATH) or "")
        build = (ok and type(decoded) == "table") and decoded or {}
    end
    return build
end

-- "261006.1 f2a1922", "f2a1922+" (untagged, uncommitted changes) or "dev".
function Version.string()
    local b = Version.build()
    if not b.commit then return "dev" end
    return (b.version and b.version .. " " or "") .. b.commit .. (b.dirty and "+" or "")
end

-- "OPENSEEK 261006.1" on a release, "OPENSEEK DEV" on any other build.
function Version.tag()
    return ("OPENSEEK " .. (Version.build().version or "dev")):upper()
end

-- "F2A1922", with a "+" when built with uncommitted changes; nil in a source
-- checkout.
function Version.commit()
    local b = Version.build()
    return b.commit and (b.commit:upper() .. (b.dirty and "+" or "")) or nil
end

-- Draws the build tag in the bottom-right corner, in raw window pixels: the
-- version in the gold CHARS font and, on a packaged build, the commit under it
-- in grey. Returns the y of its top edge.
function Version.draw(screen_w, screen_h, alpha)
    local y      = screen_h - MARGIN_Y
    local commit = Version.commit()
    if commit then
        local font = Font.get(COMMIT_FONT)
        y = y - font.line_height
        font:print(commit, screen_w - font:width(commit) - MARGIN_X, y,
            { color = { COMMIT_COLOR[1], COMMIT_COLOR[2], COMMIT_COLOR[3], alpha } })
        y = y - LINE_GAP
    end
    local font = Font.get(TAG_FONT)
    local tag  = Version.tag()
    y = y - font.line_height
    font:print(tag, screen_w - font:width(tag) - MARGIN_X, y, { color = { 1, 1, 1, alpha } })
    return y
end

return Version
