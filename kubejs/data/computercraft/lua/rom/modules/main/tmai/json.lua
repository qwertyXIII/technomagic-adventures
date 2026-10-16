-- tmai.json — JSON для запросов к LLM.
-- Свой кодировщик: textutils.serialiseJSON экранирует байты >0x7F как \u00XX (ломает UTF-8),
-- а режим unicode_strings собирает строку конкатенацией O(n^2). Здесь UTF-8 идёт как есть.
-- Свой декодер: одинаково работает в CC и в обычном Lua (для тестов), склеивает суррогатные пары.

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })
M.empty_array = setmetatable({}, { __tostring = function() return "[]" end })

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function enc_string(s, buf)
  buf[#buf + 1] = '"'
  buf[#buf + 1] = (s:gsub('[%z\1-\31"\\]', function(c)
    return ESC[c] or string.format("\\u%04x", c:byte())
  end))
  buf[#buf + 1] = '"'
end

local function is_array(t)
  if t == M.empty_array then return true end
  if next(t) == nil then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local function enc(v, buf, depth)
  if depth > 64 then error("json: too deep") end
  local tv = type(v)
  if v == nil or v == M.null then buf[#buf + 1] = "null"
  elseif tv == "boolean" then buf[#buf + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then buf[#buf + 1] = "null"
    elseif math.floor(v) == v and math.abs(v) < 2 ^ 53 then buf[#buf + 1] = string.format("%d", v)
    else buf[#buf + 1] = string.format("%.14g", v) end
  elseif tv == "string" then enc_string(v, buf)
  elseif tv == "table" then
    if is_array(v) then
      buf[#buf + 1] = "["
      for i = 1, #v do
        if i > 1 then buf[#buf + 1] = "," end
        enc(v[i], buf, depth + 1)
      end
      buf[#buf + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys) -- стабильный порядок: помогает кэшу промптов у провайдера
      buf[#buf + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then buf[#buf + 1] = "," end
        enc_string(k, buf)
        buf[#buf + 1] = ":"
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        enc(val, buf, depth + 1)
      end
      buf[#buf + 1] = "}"
    end
  else
    error("json: cannot encode " .. tv)
  end
end

function M.encode(v)
  local buf = {}
  enc(v, buf, 0)
  return table.concat(buf)
end

-- ---------------- декодер ----------------
local function utf8_char(cp)
  if utf8 and utf8.char then return utf8.char(cp) end
  error("utf8 lib missing")
end

local function decode_error(str, pos, msg)
  error(string.format("json: %s at %d near %q", msg, pos, str:sub(pos, pos + 15)), 0)
end

local parse_value

local function skip_ws(str, pos)
  return str:find("[^ \t\r\n]", pos) or (#str + 1)
end

local function parse_string(str, pos)
  local buf, i = {}, pos + 1
  while true do
    local j = str:find('["\\]', i)
    if not j then decode_error(str, pos, "unterminated string") end
    buf[#buf + 1] = str:sub(i, j - 1)
    if str:sub(j, j) == '"' then return table.concat(buf), j + 1 end
    local c = str:sub(j + 1, j + 1)
    if c == "u" then
      local hex = str:sub(j + 2, j + 5)
      local cp = tonumber(hex, 16)
      if not cp then decode_error(str, j, "bad \\u escape") end
      local nexti = j + 6
      if cp >= 0xD800 and cp <= 0xDBFF and str:sub(nexti, nexti + 1) == "\\u" then
        local lo = tonumber(str:sub(nexti + 2, nexti + 5), 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          nexti = nexti + 6
        end
      end
      if cp >= 0xD800 and cp <= 0xDFFF then cp = 0xFFFD end
      buf[#buf + 1] = utf8_char(cp)
      i = nexti
    else
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      if not map[c] then decode_error(str, j, "bad escape") end
      buf[#buf + 1] = map[c]
      i = j + 2
    end
  end
end

local function parse_array(str, pos)
  local res, n = {}, 0
  pos = skip_ws(str, pos + 1)
  if str:sub(pos, pos) == "]" then return res, pos + 1 end
  while true do
    local v
    v, pos = parse_value(str, pos)
    n = n + 1; res[n] = v
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "]" then return res, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected , or ]") end
    pos = skip_ws(str, pos + 1)
  end
end

local function parse_object(str, pos)
  local res = {}
  pos = skip_ws(str, pos + 1)
  if str:sub(pos, pos) == "}" then return res, pos + 1 end
  while true do
    if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "expected key") end
    local k
    k, pos = parse_string(str, pos)
    pos = skip_ws(str, pos)
    if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected :") end
    local v
    v, pos = parse_value(str, skip_ws(str, pos + 1))
    res[k] = v
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "}" then return res, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected , or }") end
    pos = skip_ws(str, pos + 1)
  end
end

parse_value = function(str, pos)
  pos = skip_ws(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then return parse_object(str, pos)
  elseif c == "[" then return parse_array(str, pos)
  elseif c == '"' then return parse_string(str, pos)
  elseif str:sub(pos, pos + 3) == "true" then return true, pos + 4
  elseif str:sub(pos, pos + 4) == "false" then return false, pos + 5
  elseif str:sub(pos, pos + 3) == "null" then return nil, pos + 4
  else
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num or num == "" then decode_error(str, pos, "unexpected char") end
    return tonumber(num), pos + #num
  end
end

-- Возвращает значение или nil, сообщение об ошибке.
function M.decode(str)
  if type(str) ~= "string" then return nil, "json: not a string" end
  local ok, v = pcall(parse_value, str, 1)
  if not ok then return nil, v end
  return v
end

return M
