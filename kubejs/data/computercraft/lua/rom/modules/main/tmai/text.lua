-- tmai.text — русский текст на экранах CC: Tweaked (терминал, монитор, КПК, принтер).
-- Шрифт сборки (pack/kubejs/assets/computercraft/textures/gui/term_font.png, генератор
-- tools/gen/gen_font.py) рисует кириллицу в слотах CP1251: 0xC0..0xFF = А..я, 0xA8 = Ё, 0xB8 = ё,
-- 0xB9 = №; 128..159 — псевдографика CC, прочие 160..255 — Latin-1 (« » ° © …).
-- Строки в программе храним в UTF-8, на экран выводим байты терминала (1 байт = 1 клетка).
--
--   local text = require("tmai.text")
--   text.write(t, s)          -- вывести UTF-8 строку на term/монитор/window (= t.write(text.cc(s)))
--   text.blit(t, s, fg, bg)   -- t.blit; fg/bg — цвет одной буквой ("0") или строка на каждую клетку
--   text.cc(s)                -- UTF-8 -> байты терминала; неизвестное -> "?", битый UTF-8 не роняет
--   text.utf8(b)              -- байты терминала (события char/paste, term.getLine) -> UTF-8
--   text.len(s)               -- ширина в клетках экрана (≈ число символов; «…» = 3 клетки)
--   text.chars(s)             -- массив символов UTF-8
--   text.sub(s, i, j)         -- как string.sub, но по символам
--   text.fit(s, w, ell)       -- обрезать (с хвостом ell, напр. "..") и дополнить пробелами до ширины w
--   text.wrap(s, w)           -- перенос по словам -> массив строк UTF-8 (пустые строки-абзацы сохраняются)
--   text.clean(s)             -- убрать markdown: **жирный**, `код`, ``` ограды, # заголовки, лишние пустые строки
-- ВАЖНО (Cobalt): string.lower/upper и классы %a/%w/%c на байтах >= 0x80 не используем.

local M = {}

local byte, char, sub, find, concat = string.byte, string.char, string.sub, string.find, table.concat

-- ---------------------------------------------------------------- UTF-8

-- Разобрать символ UTF-8 с позиции i -> кодовая точка (nil, если байт битый) и позиция следующего.
local function decode(s, i)
  local b = byte(s, i)
  if b < 0x80 then return b, i + 1 end
  local n, cp, min
  if b >= 0xC2 and b <= 0xDF then n, cp, min = 1, b - 0xC0, 0x80
  elseif b >= 0xE0 and b <= 0xEF then n, cp, min = 2, b - 0xE0, 0x800
  elseif b >= 0xF0 and b <= 0xF4 then n, cp, min = 3, b - 0xF0, 0x10000
  else return nil, i + 1 end
  for k = 1, n do
    local c = byte(s, i + k)
    if not c or c < 0x80 or c > 0xBF then return nil, i + 1 end
    cp = cp * 64 + (c - 0x80)
  end
  if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return nil, i + 1 end
  return cp, i + n + 1
end

local function encode(cp)
  if cp < 0x80 then return char(cp) end
  if cp < 0x800 then return char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
    0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- ---------------------------------------------------------------- таблицы перекодировки

local MAP = {}   -- кодовая точка (>= 0x80) -> байты терминала
for cp = 0x410, 0x44F do MAP[cp] = char(0xC0 + cp - 0x410) end   -- А..я
MAP[0x401] = "\168"; MAP[0x451] = "\184"; MAP[0x2116] = "\185"     -- Ё ё №
for cp = 0x80, 0xBF do MAP[cp] = char(cp) end   -- 0x80..0x9F — псевдографика CC (C1-коды), 0xA0..0xBF — Latin-1
MAP[0xA8] = '"'; MAP[0xB8] = ","; MAP[0xB9] = "1"   -- ¨ ¸ ¹: их слоты заняты Ё ё №
MAP[0xAD] = ""                                      -- мягкий перенос не рисуем
-- À..ÿ: их слоты заняты кириллицей -> латиница без диакритики
local LAT = { "A", "A", "A", "A", "A", "A", "AE", "C", "E", "E", "E", "E", "I", "I", "I", "I",
  "D", "N", "O", "O", "O", "O", "O", "x", "O", "U", "U", "U", "U", "Y", "Th", "ss",
  "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
  "d", "n", "o", "o", "o", "o", "o", "/", "o", "u", "u", "u", "u", "y", "th", "y" }
for k = 1, 64 do MAP[0xBF + k] = LAT[k] end
for _, cp in ipairs({ 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 }) do MAP[cp] = "-" end  -- тире, дефисы, минус
MAP[0x2026] = "..."
for _, cp in ipairs({ 0x201C, 0x201D, 0x201E, 0x201F, 0x2033 }) do MAP[cp] = '"' end
for _, cp in ipairs({ 0x2018, 0x2019, 0x201A, 0x201B, 0x2032 }) do MAP[cp] = "'" end
MAP[0x2039] = "<"; MAP[0x203A] = ">"
MAP[0x2248] = "~"; MAP[0x2264] = "<="; MAP[0x2265] = ">="; MAP[0x2260] = "!="
for cp = 0x2000, 0x200A do MAP[cp] = " " end                      -- типографские пробелы
MAP[0x202F] = " "; MAP[0x205F] = " "; MAP[0x3000] = " "
for _, cp in ipairs({ 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xFE0E, 0xFE0F }) do MAP[cp] = "" end  -- невидимые
-- значки CP437 из шрифта CC (как StringUtil.unicodeToCraftOsFallback в CC: Tweaked)
local SYM = { [0x263A] = 1, [0x263B] = 2, [0x2665] = 3, [0x2666] = 4, [0x2663] = 5, [0x2660] = 6, [0x2022] = 7,
  [0x25D8] = 8, [0x2642] = 11, [0x2640] = 12, [0x266A] = 14, [0x266B] = 15, [0x25BA] = 16, [0x25C4] = 17,
  [0x2195] = 18, [0x203C] = 19, [0x25AC] = 22, [0x21A8] = 23, [0x2191] = 24, [0x2193] = 25, [0x2192] = 26,
  [0x2190] = 27, [0x221F] = 28, [0x2194] = 29, [0x25B2] = 30, [0x25BC] = 31, [0x258C] = 149, [0x1FB99] = 127 }
for cp, b in pairs(SYM) do MAP[cp] = char(b) end
for cp = 0x1FB00, 0x1FB13 do MAP[cp] = char(cp - 129663) end      -- секстанты -> 129..148
for cp = 0x1FB14, 0x1FB1D do MAP[cp] = char(cp - 129662) end      -- -> 150..159

local REV = {}   -- байт терминала (>= 128) -> UTF-8
for b = 128, 255 do
  local cp = b
  if b >= 0xC0 then cp = 0x410 + b - 0xC0
  elseif b == 0xA8 then cp = 0x401
  elseif b == 0xB8 then cp = 0x451
  elseif b == 0xB9 then cp = 0x2116 end
  REV[char(b)] = encode(cp)
end

-- ---------------------------------------------------------------- перекодировка

-- UTF-8 -> байты терминала.
function M.cc(s)
  s = tostring(s == nil and "" or s)
  if not find(s, "[\128-\255\t]") then return s end
  local out, n, i, len = {}, 0, 1, #s
  while i <= len do
    local b = byte(s, i)
    if b < 0x80 then
      local j = find(s, "[\128-\255\t]", i) or len + 1
      n = n + 1
      if j > i then out[n] = sub(s, i, j - 1); i = j
      else out[n] = " "; i = i + 1 end          -- табуляция
    else
      local cp, ni = decode(s, i)
      n = n + 1
      out[n] = cp and MAP[cp] or "?"
      i = ni
    end
  end
  return concat(out)
end

-- Байты терминала -> UTF-8.
function M.utf8(b)
  b = tostring(b == nil and "" or b)
  return (b:gsub("[\128-\255]", REV))
end

-- Массив символов UTF-8 (битый байт — отдельным элементом, как есть).
function M.chars(s)
  s = tostring(s == nil and "" or s)
  local res, n, i, len = {}, 0, 1, #s
  while i <= len do
    local _, ni = decode(s, i)
    n = n + 1
    res[n] = sub(s, i, ni - 1)
    i = ni
  end
  return res
end

-- Ширина одного символа в клетках.
local function cw(ch)
  if #ch == 1 then return 1 end
  return #M.cc(ch)
end

-- Ширина строки в клетках экрана.
function M.len(s)
  s = tostring(s == nil and "" or s)
  if not find(s, "[\128-\255]") then return #s end
  return #M.cc(s)
end

-- Подстрока по символам (индексы как у string.sub, в т.ч. отрицательные).
function M.sub(s, i, j)
  local cs = M.chars(s)
  local n = #cs
  i = i or 1
  j = j or n
  if i < 0 then i = n + i + 1 end
  if j < 0 then j = n + j + 1 end
  if i < 1 then i = 1 end
  if j > n then j = n end
  if i > j then return "" end
  return concat(cs, "", i, j)
end

-- Подогнать строку под ширину w клеток: обрезать (ell — хвост при обрезке) и дополнить пробелами.
function M.fit(s, w, ell)
  s = tostring(s == nil and "" or s)
  local len = M.len(s)
  if len <= w then return s .. string.rep(" ", w - len) end
  ell = ell or ""
  local ew = M.len(ell)
  if ew > w then ell, ew = "", 0 end
  local out, used = {}, 0
  for _, ch in ipairs(M.chars(s)) do
    local k = cw(ch)
    if used + k > w - ew then break end
    out[#out + 1] = ch
    used = used + k
  end
  return concat(out) .. ell .. string.rep(" ", w - used - ew)
end

-- ---------------------------------------------------------------- перенос строк

local function is_space(ch) return ch == " " or ch == "\t" end

-- Перенос одного абзаца (без \n) в строки шириной width; результат дописывается в out.
local function wrap_para(para, width, out)
  local cs = M.chars(para)
  local n = #cs
  local line, lw = {}, 0      -- текущая строка (символы) и её ширина
  local emitted = false       -- уже выдали строку этого абзаца
  local gap = 0               -- пробелов перед следующим словом
  local function flush()
    out[#out + 1] = concat(line)
    line, lw, gap, emitted = {}, 0, 0, true
  end
  local i = 1
  while i <= n do
    if is_space(cs[i]) then
      local j = i
      while j <= n and is_space(cs[j]) do j = j + 1 end
      gap = j - i
      if lw == 0 and emitted then gap = 0 end                 -- в начале перенесённой строки пробелы не нужны
      if lw == 0 and gap >= width then gap = width - 1 end    -- отступ абзаца не шире строки
      i = j
    else
      local j, ww = i, 0
      while j <= n and not is_space(cs[j]) do ww = ww + cw(cs[j]); j = j + 1 end
      if lw > 0 and lw + gap + ww > width then flush() end
      if lw + gap + ww <= width then
        for _ = 1, gap do line[#line + 1] = " " end
        for k = i, j - 1 do line[#line + 1] = cs[k] end
        lw = lw + gap + ww
      else                                                    -- слово длиннее строки: режем
        for _ = 1, gap do line[#line + 1] = " " end
        lw = lw + gap
        for k = i, j - 1 do
          local w1 = cw(cs[k])
          if lw > 0 and lw + w1 > width then flush() end
          line[#line + 1] = cs[k]
          lw = lw + w1
        end
      end
      gap = 0
      i = j
    end
  end
  if lw > 0 or not emitted then flush() end
end

-- Перенос по словам с учётом ширины в клетках. Вход — UTF-8, выход — массив строк UTF-8.
function M.wrap(s, width)
  width = math.max(1, math.floor(tonumber(width) or 51))
  s = tostring(s == nil and "" or s):gsub("\r\n?", "\n")
  local out = {}
  for para in (s .. "\n"):gmatch("([^\n]*)\n") do
    if para == "" then out[#out + 1] = "" else wrap_para(para, width, out) end
  end
  return out
end

-- ---------------------------------------------------------------- markdown

local function trim(s)
  return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

-- Убрать markdown, который на экране CC выглядит мусором.
function M.clean(s)
  s = tostring(s == nil and "" or s):gsub("\r", "")
  s = "\n" .. s .. "\n"
  s = s:gsub("\n[ \t]*```[^\n]*", "")                     -- ограды блоков кода (строка целиком)
  s = s:gsub("%*%*(.-)%*%*", "%1")                        -- **жирный**
  s = s:gsub("`([^`\n]*)`", "%1")                         -- `код`
  s = s:gsub("\n[ \t]*#+[ \t]*", "\n")                    -- # заголовки
  s = s:gsub("\n([ \t]*)[%*%+][ \t]+", "\n%1- ")          -- * пункт -> - пункт
  s = s:gsub("%[([^%]\n]+)%]%((https?://[^%)%s]+)%)", "%1 (%2)")  -- [текст](ссылка)
  s = s:gsub("[ \t]+\n", "\n")                            -- хвостовые пробелы
  s = s:gsub("\n\n\n+", "\n\n")
  return trim(s)
end

-- ---------------------------------------------------------------- вывод

-- Вывести UTF-8 строку на term-подобный объект (term, монитор, window) с текущей позиции.
function M.write(t, s)
  t.write(M.cc((tostring(s == nil and "" or s):gsub("[\r\n]", " "))))
end

-- t.blit для UTF-8 строки; fg/bg — один символ цвета ("0".."f") или строка на каждую клетку.
function M.blit(t, s, fg, bg)
  local b = M.cc((tostring(s == nil and "" or s):gsub("[\r\n]", " ")))
  local n = #b
  local function stretch(c)
    c = tostring(c)
    if #c == n then return c end
    if #c == 0 then c = "0" end
    return sub(c .. string.rep(sub(c, -1), n), 1, n)
  end
  t.blit(b, stretch(fg), stretch(bg))
end

return M
