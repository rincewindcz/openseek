-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Console log: one line per notable event, stamped with seconds since the first
-- logged line (the startup line) and tagged with the subsystem that emitted it.
-- Never called per tick, and it never touches simulation state, so logging
-- cannot affect a replay. The clock is read on first use, not at require time,
-- so the headless tools can load modules without stubbing love.timer. The last
-- lines are kept for the crash report (engine/ui/error_screen.lua).
local Log = {}

local RECENT_MAX = 80

local start
local recent = {}

local function emit(level, tag, fmt, ...)
    local now = love.timer.getTime()
    start = start or now
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    local line = ("[%9.3f] %s%s: %s"):format(now - start, level, tag, msg)
    print(line)
    recent[#recent + 1] = line
    if #recent > RECENT_MAX then table.remove(recent, 1) end
end

function Log.info(tag, fmt, ...) emit("", tag, fmt, ...) end
function Log.warn(tag, fmt, ...) emit("WARN ", tag, fmt, ...) end

-- The last RECENT_MAX lines logged, oldest first.
function Log.recent() return recent end

return Log
