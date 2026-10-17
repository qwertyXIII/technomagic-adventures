-- tmai.extras — атмосфера рубки: принтер «Восстановленных записей» (по-русски: шрифт с кириллицей), сигнал колонки, напевание.
-- Всё необязательно: нет принтера/колонки — функции тихо ничего не делают.

local util = require("tmai.util")
local text = require("tmai.text")

local M = {}
local printer, speaker

function M.attach()
  printer = peripheral.find("printer")
  speaker = peripheral.find("speaker")
end

function M.print_record(n, title, body)
  if not printer then return false end
  local ok = pcall(function()
    if printer.getPaperLevel() < 1 or printer.getInkLevel() < 1 then return end
    if not printer.newPage() then return end
    local w, h = printer.getPageSize()
    printer.setPageTitle(text.cc("Запись " .. n))
    local lines = { "ВОССТАНОВЛЕННАЯ ЗАПИСЬ " .. n }
    for _, l in ipairs(text.wrap(title, w)) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    for _, l in ipairs(text.wrap(body, w)) do lines[#lines + 1] = l end
    for i = 1, math.min(#lines, h) do
      printer.setCursorPos(1, i)
      printer.write(text.cc(lines[i]))
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
