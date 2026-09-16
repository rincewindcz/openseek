-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Minimal JSON codec, sufficient for the stage exports and the save files:
-- objects, arrays, strings without exotic escapes, numbers, booleans, null.

local json = {}

local function skipws(s, i)
  return (s:find("[^ \t\r\n]", i)) or #s + 1
end

local decode_value

local function decode_string(s, i)
  -- i points at the opening quote
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("unterminated string at " .. i) end
    if c == '"' then break end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if map[e] then
        out[#out + 1] = map[e]
        j = j + 2
      elseif e == "u" then
        local hex = s:sub(j + 2, j + 5)
        out[#out + 1] = string.char(tonumber(hex, 16) % 256)
        j = j + 6
      else
        error("bad escape \\" .. e .. " at " .. j)
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
  return table.concat(out), j + 1
end

local function decode_number(s, i)
  local j = s:find("[^-+0-9.eE]", i) or #s + 1
  local n = tonumber(s:sub(i, j - 1))
  if n == nil then error("bad number at " .. i) end
  return n, j
end

local function decode_array(s, i)
  local arr, j = {}, skipws(s, i + 1)
  if s:sub(j, j) == "]" then return arr, j + 1 end
  while true do
    local v
    v, j = decode_value(s, j)
    arr[#arr + 1] = v
    j = skipws(s, j)
    local c = s:sub(j, j)
    if c == "]" then return arr, j + 1 end
    if c ~= "," then error("expected , or ] at " .. j) end
    j = skipws(s, j + 1)
  end
end

local function decode_object(s, i)
  local obj, j = {}, skipws(s, i + 1)
  if s:sub(j, j) == "}" then return obj, j + 1 end
  while true do
    if s:sub(j, j) ~= '"' then error("expected key at " .. j) end
    local k, v
    k, j = decode_string(s, j)
    j = skipws(s, j)
    if s:sub(j, j) ~= ":" then error("expected : at " .. j) end
    v, j = decode_value(s, skipws(s, j + 1))
    obj[k] = v
    j = skipws(s, j)
    local c = s:sub(j, j)
    if c == "}" then return obj, j + 1 end
    if c ~= "," then error("expected , or } at " .. j) end
    j = skipws(s, j + 1)
  end
end

decode_value = function(s, i)
  local c = s:sub(i, i)
  if c == '"' then return decode_string(s, i) end
  if c == "{" then return decode_object(s, i) end
  if c == "[" then return decode_array(s, i) end
  if c == "t" then return true, i + 4 end
  if c == "f" then return false, i + 5 end
  if c == "n" then return nil, i + 4 end
  return decode_number(s, i)
end

function json.decode(s)
  local v = decode_value(s, skipws(s, 1))
  return v
end

-- Encoder. Tables with a positive length are arrays, every other table is an
-- object with its keys sorted, so the same data always encodes byte for byte the
-- same (save files stay diffable).

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
                  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("cannot encode " .. tostring(n))
  end
  if n == math.floor(n) then return string.format("%d", n) end
  return string.format("%.14g", n)
end

local encode_value

local function encode_array(t, indent)
  local inner, parts = indent .. "  ", {}
  for i = 1, #t do
    parts[i] = inner .. encode_value(t[i], inner)
  end
  return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
end

local function encode_object(t, indent)
  local keys = {}
  for k in pairs(t) do
    if type(k) ~= "string" then error("object key must be a string") end
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local inner, parts = indent .. "  ", {}
  for i, k in ipairs(keys) do
    parts[i] = inner .. encode_string(k) .. ": " .. encode_value(t[k], inner)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

encode_value = function(v, indent)
  local kind = type(v)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return tostring(v) end
  if kind == "number" then return encode_number(v) end
  if kind == "string" then return encode_string(v) end
  if kind ~= "table" then error("cannot encode " .. kind) end
  if next(v) == nil then return "{}" end
  if #v > 0 then return encode_array(v, indent) end
  return encode_object(v, indent)
end

function json.encode(v)
  return encode_value(v, "")
end

return json
