-- Minimal JSON decoder (decode only), sufficient for the stage exports:
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

return json
