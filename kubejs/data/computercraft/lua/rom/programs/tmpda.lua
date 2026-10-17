-- tmpda — приложение «КПК»: разговор с ЛОЦМАНом вдали от капсулы.
-- Карманный компьютер с беспроводным модемом (дальность мала у земли и растёт с высотой; вышки продлевают)
-- или с эндер-модемом (без ограничений, из любых измерений). Вопросы уходят по rednet (протокол tmai_radio)
-- на компьютер капсулы, ответы и объявления капсулы (поручения, находки, программы) показываются здесь.
-- Пишите по-русски как обычно (шрифт CC в сборке с кириллицей). «да 123» — подтвердить, «стоп» — остановить.
-- С апгрейдом «динамик» КПК проигрывает озвучку, если она включена у капсулы.
-- Сменить имя: set tmpda.player <ник>; забыть капсулу: set tmpda.ai_id (пусто).

local text = require("tmai.text")
local input = require("tmai.input")

local PROTO = "tmai_radio"
local FEED = "/tmpda/feed.json"
local MAX = 80

local opened = false
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.hasType(n, "modem") then rednet.open(n); opened = true end
end
if not opened and pocket then pcall(pocket.equipBack) end
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.hasType(n, "modem") then rednet.open(n); opened = true end
end
if not opened then printError(text.cc("В КПК нет модема: соберите его с беспроводным или эндер-модемом.")); return end

local w, h = term.getSize()
local speaker = peripheral.find("speaker")
local AI = settings.get("tmpda.ai_id")

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
  term.write(text.cc(s))
end

-- ---------- имя игрока ----------
local NAME = settings.get("tmpda.player") or ""
if NAME == "" then
  term.setBackgroundColor(colors.black); term.clear()
  put(1, 1, "КПК: первый запуск", colors.cyan)
  put(1, 3, "Ваш ник в игре:", colors.white)
  local ned = input.new({ term = term, x = 1, y = 4, width = w, prompt = "> ", max = 32, history = false, prompt_fg = colors.yellow })
  ned:draw()
  while NAME == "" do
    local ev = { os.pullEvent() }
    local r, s = ned:handle(table.unpack(ev))
    if r == "submit" then NAME = (s or ""):gsub("[^%w_]", "") end
    ned:draw()
  end
  settings.set("tmpda.player", NAME); settings.save()
end

-- ---------- лента ----------
local feed = {}
do
  local f = fs.open(FEED, "r")
  if f then
    local ok, v = pcall(textutils.unserialiseJSON, f.readAll()); f.close()
    if ok and type(v) == "table" then feed = v end
  end
end
local function save_feed()
  if not fs.exists("/tmpda") then fs.makeDir("/tmpda") end
  local f = fs.open(FEED, "w")
  if f then f.write(textutils.serialiseJSON(feed)); f.close() end
end
local function add(kind, who, s)
  feed[#feed + 1] = { kind = kind, who = who, text = tostring(s or "") }
  while #feed > MAX do table.remove(feed, 1) end
  save_feed()
end

local NAME_FG = { user = colors.yellow, ai = colors.cyan, sys = colors.lightGray, warn = colors.orange }

local scroll = 0
local link = AI and "?" or "поиск"
local waiting = nil      -- { deadline } пока ждём ответ
local ed = input.new({ term = term, x = 1, y = h, width = w, prompt = "> ", max = 400, history = true,
  prompt_fg = colors.yellow, placeholder = "Вопрос Лоцману…" })

local function lines()
  local out = {}
  for _, it in ipairs(feed) do
    local head = (it.who or "?") .. ": "
    for i, l in ipairs(text.wrap(head .. text.clean(it.text), w)) do
      out[#out + 1] = { s = l, kind = it.kind, head = i == 1 and text.len(head) or 0 }
    end
  end
  return out
end

local function draw()
  term.setCursorBlink(false)
  term.setBackgroundColor(colors.gray); term.setCursorPos(1, 1); term.clearLine()
  put(1, 1, "КПК · ЛОЦМАН", colors.white, colors.gray)
  local st = waiting and "жду ответ" or link
  put(w - text.len(st) + 1, 1, st, link == "нет связи" and colors.orange or colors.white, colors.gray)
  local all = lines()
  local rows = h - 3
  local last = #all - scroll
  local first = math.max(1, last - rows + 1)
  for y = 2, h - 2 do term.setBackgroundColor(colors.black); term.setCursorPos(1, y); term.clearLine() end
  local y = 2 + rows - (last - first + 1)
  for i = first, last do
    local l = all[i]
    if l.head > 0 then
      put(1, y, text.sub(l.s, 1, l.head), NAME_FG[l.kind] or colors.white, colors.black)
      put(1 + l.head, y, text.sub(l.s, l.head + 1), colors.white)
    else
      put(1, y, l.s, colors.white, colors.black)
    end
    y = y + 1
  end
  term.setBackgroundColor(colors.black); term.setCursorPos(1, h - 1); term.clearLine()
  put(1, h - 1, text.fit(scroll > 0 and "PgDn — к последним" or ("Вы: " .. NAME), w), colors.gray, colors.black)
  ed:draw()
end

-- ---------- звук ----------
local audio = {}
local function play_next()
  if not speaker then audio = {}; return end
  while audio[1] do
    if speaker.playAudio(audio[1]) then table.remove(audio, 1) else return end
  end
end

local function send(msg)
  if AI then rednet.send(AI, msg, PROTO) else rednet.broadcast(msg, PROTO) end
end

if #feed == 0 then add("sys", "КПК", "Связь с капсулой по радио. Пишите вопрос и Enter.") end
send({ op = "ping", player = NAME })
local ping_timer = os.startTimer(5)
draw()

while true do
  local ev = { os.pullEvent() }
  local e = ev[1]
  if e == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" then
    local id, m = ev[2], ev[3]
    if (m.op == "answer" or m.op == "notify" or m.op == "pong") and (not AI or id == AI) then
      if not AI then AI = id; settings.set("tmpda.ai_id", id); settings.save() end
      link = "на связи"
      if m.op == "answer" then
        waiting = nil
        add("ai", m.from or "ЛОЦМАН", m.text)
      elseif m.op == "notify" then
        add("ai", m.from or "ЛОЦМАН", m.text)
        if speaker then pcall(speaker.playNote, "chime", 0.6, 12) end
      end
      scroll = 0
      draw()
    elseif m.op == "audio" and id == AI and type(m.data) == "string" then
      local chunk = {}
      for i = 1, #m.data do chunk[i] = m.data:byte(i) - 128 end
      audio[#audio + 1] = chunk
      play_next()
    end
  elseif e == "speaker_audio_empty" then
    play_next()
  elseif e == "timer" and ev[2] == ping_timer then
    if waiting and os.clock() > waiting.deadline then
      waiting = nil; link = "нет связи"
      add("warn", "КПК", "Нет ответа: капсула вне зоны связи или занята.")
    elseif not waiting then
      if link == "?" or link == "поиск" then link = "нет связи" end
      send({ op = "ping", player = NAME })
    end
    ping_timer = os.startTimer(waiting and 5 or 60)
    draw()
  elseif e == "mouse_scroll" or (e == "key" and (ev[2] == keys.pageUp or ev[2] == keys.pageDown)) then
    local up = (e == "mouse_scroll" and ev[2] < 0) or (e == "key" and ev[2] == keys.pageUp)
    scroll = math.max(0, scroll + (up and 3 or -3))
    draw()
  else
    local r, s = ed:handle(table.unpack(ev))
    if r == "submit" and s and s:match("%S") then
      if s == "exit" or s == "выход" then term.clear(); term.setCursorPos(1, 1); return end
      add("user", NAME, s)
      send({ op = "ask", player = NAME, text = s })
      waiting = { deadline = os.clock() + 180 }
      scroll = 0
      draw()
    elseif r then
      ed:draw()
    end
  end
end
