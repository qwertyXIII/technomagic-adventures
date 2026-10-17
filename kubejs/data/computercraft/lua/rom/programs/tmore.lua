-- tmore — «Рудоискатель»: КПК, компьютер или черепашка с геосканером (Advanced Peripherals).
-- КПК: улучшение «Геосканер» ставится вместо модема (у КПК одно место под улучшение). Радиус 8 блоков —
-- без топлива (больше КПК не может; блок-сканеру с энергией: tmore 16).
-- Экран: руды вокруг по видам — сколько и где ближайшая: «5 СВ -3» — 5 блоков на северо-восток, на 3 ниже
-- (север — минус Z, туда же стрелка компаса). Enter — все блоки вида, Backspace — назад.
-- Сканирует сам раз в 3 с (у сканера перезарядка), пока идёте. R — сейчас, F — фильтр по названию, Q — выход.
local args = { ... }
local text = require("tmai.text")
local input = require("tmai.input")
local ore = require("tmai.ore")

local scanner = peripheral.find("geo_scanner")
if not scanner then
  printError(text.cc("Нужен геосканер: КПК с улучшением «Геосканер» (Advanced Peripherals) или сканер рядом."))
  return
end
local scan = scanner.scanBlocks or scanner.scan
local RADIUS = math.max(1, math.min(16, tonumber(args[1]) or 8))
local PERIOD = 3

local w, h = term.getSize()
local blocks, groups = {}, {}
local err, scanned = nil, false
local sel, top, open = 1, 1, nil     -- open — материал, чьи блоки показаны
local filter = ""
local fed = nil                       -- строка ввода фильтра

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
  term.write(text.cc(s))
end

local function regroup() groups = ore.group(blocks, filter) end

local function do_scan()
  local ok, res, e = pcall(scan, RADIUS)
  if ok and type(res) == "table" then
    blocks, err, scanned = res, nil, true
    regroup()
  else
    err = ok and tostring(e or "нет ответа") or tostring(res)
    if err:find("Radius", 1, true) and RADIUS > 8 then RADIUS = 8 end   -- нет топлива/предел — без топлива
  end
end

local function current_group()
  if not open then return nil end
  for _, g in ipairs(groups) do if g.material == open then return g end end
  return nil
end

local function draw()
  term.setCursorBlink(false)
  term.setBackgroundColor(colors.black); term.clear()
  term.setBackgroundColor(colors.gray); term.setCursorPos(1, 1); term.clearLine()
  put(1, 1, text.fit("Рудоискатель", w - 5), colors.white, colors.gray)
  put(w - 3, 1, ("r" .. RADIUS):sub(1, 4), colors.lightGray, colors.gray)
  term.setBackgroundColor(colors.black)
  local rows = h - 3                          -- строки 3..h-1
  local g = current_group()
  if open and not g then open = nil end
  if g then
    put(1, 2, text.fit(g.name .. " x" .. g.count, w), colors.cyan, colors.black)
    for i = 1, math.min(rows, #g.blocks) do
      local b = g.blocks[i]
      local coords = ("x%+d z%+d"):format(math.floor(b.x + 0.5), math.floor(b.z + 0.5))
      local left = text.fit(ore.where(b), w - #coords - 1)
      put(1, 2 + i, left, colors.white, colors.black)
      put(w - #coords + 1, 2 + i, coords, colors.gray, colors.black)
    end
    if #g.blocks > rows then put(1, h - 1, text.fit("…и ещё " .. (#g.blocks - rows), w), colors.gray, colors.black) end
  else
    put(1, 2, text.fit(filter ~= "" and ("фильтр: " .. filter) or "руды вокруг", w), colors.lightGray, colors.black)
    if not scanned then
      put(1, 4, text.fit(err and ("Сканер: " .. err) or "Сканирую…", w), err and colors.orange or colors.gray, colors.black)
    elseif #groups == 0 then
      put(1, 4, text.fit(filter ~= "" and "Такой руды рядом нет." or ("Руды в радиусе " .. RADIUS .. " нет."), w), colors.gray, colors.black)
    end
    sel = math.max(1, math.min(sel, #groups))
    if sel < top then top = sel end
    if sel > top + rows - 1 then top = sel - rows + 1 end
    for i = top, math.min(#groups, top + rows - 1) do
      local gr = groups[i]
      local y = 3 + i - top
      local cur = i == sel
      local bg = cur and colors.gray or colors.black
      local where = ore.where(gr.blocks[1])
      local cnt = "x" .. gr.count
      local namew = w - text.len(where) - #cnt - 2
      term.setBackgroundColor(bg); term.setCursorPos(1, y); term.clearLine()
      put(1, y, text.fit(gr.name, math.max(4, namew)), colors.white, bg)
      put(math.max(5, namew) + 1, y, " " .. cnt, colors.lightGray, bg)
      put(w - text.len(where) + 1, y, where, colors.yellow, bg)
      term.setBackgroundColor(colors.black)
    end
  end
  -- нижняя строка: ввод фильтра, ошибка или подсказка
  if fed then
    fed:draw()
  else
    local hint = open and "Bksp назад · R скан · Q выход" or "Enter блоки · F фильтр · R · Q"
    if err and scanned then hint = "сканер: " .. err end
    put(1, h, text.fit(hint, w), err and scanned and colors.orange or colors.gray, colors.black)
  end
end

do_scan()
draw()
local timer = os.startTimer(PERIOD)
while true do
  local ev = { os.pullEvent() }
  local e = ev[1]
  if fed then
    local r, s = fed:handle(table.unpack(ev))
    if r == "submit" then filter = s or ""; fed = nil; sel, top = 1, 1; regroup(); draw()
    elseif e == "key" and (ev[2] == keys.up or ev[2] == keys.down or ev[2] == keys.tab) then fed = nil; draw()
    elseif r then fed:draw() end
    if e == "timer" and ev[2] == timer then do_scan(); timer = os.startTimer(PERIOD); draw() end
  elseif e == "timer" and ev[2] == timer then
    do_scan(); timer = os.startTimer(PERIOD); draw()
  elseif e == "key" then
    local k = ev[2]
    if k == keys.q then term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1); return
    elseif k == keys.r then do_scan(); draw()
    elseif k == keys.f and not open then
      fed = input.new({ term = term, x = 1, y = h, width = w, prompt = "Найти: ", max = 24, history = false,
        placeholder = "алмаз, медь…" })
      fed:set(filter); draw()
    elseif k == keys.up and not open then sel = math.max(1, sel - 1); draw()
    elseif k == keys.down and not open then sel = math.min(#groups, sel + 1); draw()
    elseif k == keys.enter and not open and groups[sel] then open = groups[sel].material; draw()
    elseif (k == keys.backspace or k == keys.enter) and open then open = nil; draw()
    end
  elseif e == "mouse_click" and not open then
    local i = top + ev[4] - 3
    if groups[i] and ev[4] >= 3 and ev[4] <= h - 1 then
      if sel == i then open = groups[i].material else sel = i end
      draw()
    end
  elseif e == "mouse_scroll" and not open then
    sel = math.max(1, math.min(#groups, sel + ev[2])); draw()
  elseif e == "term_resize" then
    w, h = term.getSize(); draw()
  end
end
