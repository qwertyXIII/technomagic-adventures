-- tmai.u8 — помощники для UTF-8 строк (русский текст) в CC: Tweaked.
-- ВАЖНО: в Cobalt string.lower/upper и классы %a/%w/%s могут трактовать байты
-- 0x80-0xFF как Latin-1 и портить UTF-8. Поэтому здесь только явные байтовые диапазоны.

local M = {}

-- ASCII + кириллица в нижний регистр; "ё" нормализуется в "е" (для поиска).
function M.lower(s)
  s = s:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)
  s = s:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end) -- А-П -> а-п
  s = s:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end) -- Р-Я -> р-я
  s = s:gsub("\208\129", "\208\181") -- Ё -> е
  s = s:gsub("\209\145", "\208\181") -- ё -> е
  return s
end

function M.trim(s)
  return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

-- Число символов (кодовых точек); на битом UTF-8 — число байт.
function M.len(s)
  local ok, n = pcall(utf8.len, s)
  if ok and n then return n end
  return #s
end

-- Безопасная позиция обрезки: не режем посреди многобайтного символа.
local function safe_cut(s, pos)
  if pos >= #s then return #s end
  while pos > 0 do
    local b = s:byte(pos + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    pos = pos - 1
  end
  return pos
end
M.safe_cut = safe_cut

-- Обрезать до max_bytes байт с многоточием.
function M.truncate(s, max_bytes)
  if #s <= max_bytes then return s end
  return s:sub(1, safe_cut(s, max_bytes - 3)) .. "..."
end

-- Разбить текст на куски не длиннее max_bytes байт (лимит чат-бокса считается в байтах,
-- т.к. AP проверяет длину ДО перекодировки utf8). Режем по абзацу, предложению, пробелу.
function M.chunks(text, max_bytes)
  local out = {}
  text = M.trim(text)
  while #text > max_bytes do
    local window = text:sub(1, safe_cut(text, max_bytes))
    local cut
    for _, pat in ipairs({ "()\n[^\n]*$", "()[%.!%?][ \n][^%.!%?]*$", "()[ ][^ ]*$" }) do
      local p = window:match(pat)
      if p and p > max_bytes * 0.4 then cut = p; break end
    end
    cut = cut or #window
    local piece = M.trim(text:sub(1, cut))
    if #piece > 0 then out[#out + 1] = piece end
    text = M.trim(text:sub(cut + 1))
  end
  if #text > 0 then out[#out + 1] = text end
  return out
end

-- Убрать из ответа модели то, что плохо выглядит в чате Minecraft.
function M.clean_for_chat(s)
  s = s:gsub("\r", "")
  s = s:gsub("%*%*(.-)%*%*", "%1")      -- **жирный**
  s = s:gsub("`([^`]*)`", "%1")          -- `код`
  s = s:gsub("\n#+ *", "\n")             -- заголовки markdown
  s = s:gsub("\194\167", "")             -- символ параграфа (коды форматирования MC)
  s = s:gsub("\n\n\n+", "\n\n")
  return M.trim(s)
end

-- Токены для поиска: слова из [0-9a-z_] и байтов >= 0x80 (кириллица).
-- Стемминг: первые 5 символов слова (для слов длиннее 5).
local PUNCT = { "\194\171", "\194\187", "\226\128\148", "\226\128\147", "\226\128\166", "\226\128\156", "\226\128\157" }
function M.tokens(s, min_len)
  min_len = min_len or 3
  s = M.lower(s)
  for _, p in ipairs(PUNCT) do s = s:gsub(p, " ") end
  local res, seen = {}, {}
  for w in s:gmatch("[0-9a-z_\128-\255]+") do
    local n = M.len(w)
    if n >= min_len then
      local stem = w
      if n > 5 then
        local ok, off = pcall(utf8.offset, w, 6)
        if ok and off then stem = w:sub(1, off - 1) end
      end
      if not seen[stem] then seen[stem] = true; res[#res + 1] = stem end
    end
  end
  return res
end

-- Начинается ли строка с одного из слов-обращений; вернуть остаток.
function M.strip_trigger(text, triggers)
  local low = M.lower(M.trim(text))
  for _, t in ipairs(triggers) do
    local tl = M.lower(t)
    if low:sub(1, #tl) == tl then
      local nextc = low:sub(#tl + 1, #tl + 1)
      if nextc == "" or nextc:match("[ ,:!%?%.]") then
        local rest = M.trim(text):sub(#tl + 1)
        rest = rest:gsub("^[ ,:!%.]+", "")
        return true, M.trim(rest)
      end
    end
  end
  return false
end

function M.split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
  return out
end

return M
