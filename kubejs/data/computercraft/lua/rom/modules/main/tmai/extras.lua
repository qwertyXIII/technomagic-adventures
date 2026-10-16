-- tmai.extras — атмосфера рубки: принтер «Восстановленных записей», сигнал колонки, напевание.
-- Всё необязательно: нет принтера/колонки — функции тихо ничего не делают.

local util = require("tmai.util")

local M = {}
local printer, speaker

function M.attach()
  printer = peripheral.find("printer")
  speaker = peripheral.find("speaker")
end

-- Шрифт CC не рисует кириллицу: на бумаге — транслит.
local TR = { ["а"] = "a", ["б"] = "b", ["в"] = "v", ["г"] = "g", ["д"] = "d", ["е"] = "e", ["ё"] = "e", ["ж"] = "zh", ["з"] = "z",
  ["и"] = "i", ["й"] = "j", ["к"] = "k", ["л"] = "l", ["м"] = "m", ["н"] = "n", ["о"] = "o", ["п"] = "p", ["р"] = "r", ["с"] = "s",
  ["т"] = "t", ["у"] = "u", ["ф"] = "f", ["х"] = "h", ["ц"] = "c", ["ч"] = "ch", ["ш"] = "sh", ["щ"] = "sch", ["ъ"] = "", ["ы"] = "y",
  ["ь"] = "'", ["э"] = "e", ["ю"] = "yu", ["я"] = "ya", ["«"] = "\"", ["»"] = "\"", ["—"] = "-", ["…"] = "...", ["№"] = "N" }

function M.translit(s)
  local u8 = require("tmai.u8")
  local out = {}
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    local low = u8.lower(ch)
    local t = TR[low]
    if t then
      if low ~= ch and #t > 0 then t = t:sub(1, 1):upper() .. t:sub(2) end
      out[#out + 1] = t
    elseif cp < 128 then
      out[#out + 1] = ch
    else
      out[#out + 1] = "?"
    end
  end
  return table.concat(out)
end

local function wrap(text, width)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      if #line + #word + 1 > width then lines[#lines + 1] = line; line = word
      else line = (line == "" and word or line .. " " .. word) end
    end
    lines[#lines + 1] = line
  end
  return lines
end

function M.print_record(n, title, text)
  if not printer then return false end
  local ok = pcall(function()
    if printer.getPaperLevel() < 1 or printer.getInkLevel() < 1 then return end
    if not printer.newPage() then return end
    local w, h = printer.getPageSize()
    printer.setPageTitle("Record L" .. n)
    local lines = { "VOSSTANOVLENNAYA ZAPIS' L" .. n, M.translit(title), "" }
    for _, l in ipairs(wrap(M.translit(text), w)) do lines[#lines + 1] = l end
    for i = 1, math.min(#lines, h) do
      printer.setCursorPos(1, i)
      printer.write(lines[i])
    end
    printer.endPage()
  end)
  return ok
end

function M.chime()
  if not speaker then return end
  pcall(speaker.playNote, "chime", 1.0, 12)
  sleep(0.3)
  pcall(speaker.playNote, "chime", 1.0, 17)
end

-- Колыбельная: playNote 0..24 (0 = F#3); 0 в длительности = долгая нота.
local LULLABY = {
  { 10, 15, 15, 13, 15, 18, 17, 0 },
  { 17, 15, 13, 10, 11, 10, 8, 0 },
  { 10, 10, 15, 15, 13, 15, 17 },
  { 18, 17, 15, 13, 10, 13, 15, 0 },
}

-- major = «Утренняя» (та же мелодия на полтона выше в ключевых местах)
function M.hum(major)
  if not speaker then return false end
  for _, phrase in ipairs(LULLABY) do
    for i, note in ipairs(phrase) do
      if note ~= 0 then
        local n = note
        if major and n == 18 then n = 19 elseif major and n == 13 then n = 14 end
        local long = phrase[i + 1] == 0
        pcall(speaker.playNote, "harp", 0.5, n)
        sleep(long and 0.8 or 0.4)
      end
    end
    sleep(0.6)
  end
  util.log("D", "hummed")
  return true
end

return M
