-- tmpda.core — КПК как маленькая ОС: вкладки Чат / Метки / Почта / Тревоги / Склад, радио с капсулой (rednet tmai_radio),
-- запросы к приложениям капсулы и общие службы для вкладок. Сам ничего не ждёт: события скармливает программа
-- tmpda (K:handle), так же его гоняют офлайн-тесты.
--
-- Экран 26×20: 1 — шапка (ник, связь); 2 — вкладки (Tab / Shift+Tab, щелчок; не влезают — короткие имена);
--   3..h-2 — вкладка;
--   h-1 — состояние вкладки или короткое сообщение; h — строка ввода или подсказка.
-- Радио: вопрос {op="ask", player, text} -> {op="answer", text}; {op="ping"} -> {op="pong"};
--   объявления капсулы {op="notify", text, level?, from, app?}; озвучка {op="audio", data};
--   запросы приложений {op="app", app, act, rid, player, …} -> {op="app_reply", app, act, rid, data|error}
--   (таймаут TIMEOUT с — «нет связи с капсулой»).
-- Вкладка — модуль tmpda.<id>: { id, title, short, init(K), show(K), draw(K, x, y, w, h), key(K, ev, a, b, c),
--   click(K, x, y), status(K) -> текст, цвет; hint(K) -> текст; badge(K) -> цвет|nil; bottom(K) (своя строка h),
--   tick(K), notify(K, msg), radio(K, id, msg) }.
-- Службы: K:request(app, act, fields, cb(data, err)), K:ask(метка, opts, cb(текст)), K:flash(текст, цвет),
--   K:confirm(ключ, текст) -> true при повторе за 4 с, K:load/save(имя, значение) — файлы /tmpda/<имя>.json,
--   K:put(x, y, s, fg, bg), K:stamp() -> «12:00 д.3», K:clock().

local text = require("tmai.text")
local input = require("tmai.input")

local M = {}
local K = {}
K.__index = K

M.PROTO = "tmai_radio"
M.TIMEOUT = 15
M.TABS = { "chat", "wp", "mail", "alerts", "storage" }

local function encode(v)
  if textutils and textutils.serialiseJSON then return textutils.serialiseJSON(v) end
  return require("tmai.json").encode(v)
end
local function decode(s)
  if textutils and textutils.unserialiseJSON then return textutils.unserialiseJSON(s) end
  return require("tmai.json").decode(s)
end

-- o = { term, name, ai, send(id|nil, msg), set_ai(id), speaker, dir = "/tmpda", clock = os.clock }
function M.new(o)
  local self = setmetatable({}, K)
  self.t = o.term or term
  self.w, self.h = self.t.getSize()
  self.name = o.name
  self.ai = o.ai
  self.send_fn = o.send or function() end
  self.set_ai_fn = o.set_ai or function() end
  self.speaker = o.speaker
  self.dir = o.dir or "/tmpda"
  self.clock_fn = o.clock or os.clock
  self.link = o.ai and "?" or "поиск"
  self.pending, self.rid = {}, math.floor(self.clock_fn() * 10) % 1000
  self.audio = {}
  self.shift = false
  self.st = {}
  self.tabs = {}
  for _, id in ipairs(o.tabs or M.TABS) do
    local tab = require("tmpda." .. id)
    self.tabs[#self.tabs + 1] = tab
    self.st[id] = {}
  end
  self.cur = 1
  for _, tab in ipairs(self.tabs) do if tab.init then tab.init(self, self.st[tab.id]) end end
  return self
end

function K:clock() return self.clock_fn() end
function K:tab() return self.tabs[self.cur] end
function K:state(id) return self.st[id] end

function K:put(x, y, s, fg, bg)
  local t = self.t
  t.setCursorPos(x, y)
  if fg then t.setTextColor(fg) end
  if bg then t.setBackgroundColor(bg) end
  t.write(text.cc(s))
end

function K:stamp()
  local tm = textutils and textutils.formatTime and textutils.formatTime(os.time(), true) or "?"
  return tm .. " д." .. tostring(os.day and os.day() or "?")
end

-- ---------- файлы ----------
function K:load(name, default)
  local f = fs.open(self.dir .. "/" .. name .. ".json", "r")
  if not f then return default end
  local s = f.readAll()
  f.close()
  local ok, v = pcall(decode, s or "")
  if ok and type(v) == "table" then return v end
  return default
end

function K:save(name, value)
  if not fs.exists(self.dir) then fs.makeDir(self.dir) end
  local ok, s = pcall(encode, value)
  if not ok then return false end
  local f = fs.open(self.dir .. "/" .. name .. ".json", "w")
  if not f then return false end
  f.write(s)
  f.close()
  return true
end

-- ---------- радио ----------
function K:send(msg) self.send_fn(self.ai, msg) end

function K:request(app, act, fields, cb)
  self.rid = self.rid + 1
  local msg = { op = "app", app = app, act = act, rid = self.rid, player = self.name }
  for k, v in pairs(fields or {}) do msg[k] = v end
  self.pending[self.rid] = { cb = cb, deadline = self:clock() + M.TIMEOUT, app = app, act = act }
  self:send(msg)
  return self.rid
end

function K:busy()
  for _ in pairs(self.pending) do return true end
  return false
end

local function call(cb, ...)
  if not cb then return end
  local ok, err = pcall(cb, ...)
  if not ok and printError then pcall(printError, tostring(err)) end
end

function K:play_next()
  local sp = self.speaker
  if not sp then self.audio = {}; return end
  while self.audio[1] do
    if sp.playAudio(self.audio[1]) then table.remove(self.audio, 1) else return end
  end
end

function K:on_radio(id, m)
  if type(m) ~= "table" then return end
  local known = { answer = true, notify = true, pong = true, app_reply = true }
  if known[m.op] and (not self.ai or id == self.ai) then
    if not self.ai then self.ai = id; self.set_ai_fn(id) end
    self.link, self.last_ok = "на связи", self:clock()
    if m.op == "app_reply" then
      local p = self.pending[m.rid]
      if p then
        self.pending[m.rid] = nil
        if m.error ~= nil then call(p.cb, nil, tostring(m.error)) else call(p.cb, m.data, nil) end
      end
    elseif m.op == "notify" then
      for _, tab in ipairs(self.tabs) do if tab.notify then tab.notify(self, m) end end
      if self.speaker then
        if m.level == "crit" then pcall(self.speaker.playNote, "bell", 1, 18)
        else pcall(self.speaker.playNote, "chime", 0.6, 12) end
      end
    end
    for _, tab in ipairs(self.tabs) do if tab.radio then tab.radio(self, id, m) end end
  elseif m.op == "audio" and id == self.ai and type(m.data) == "string" then
    local chunk = {}
    for i = 1, #m.data do chunk[i] = m.data:byte(i) - 128 end
    self.audio[#self.audio + 1] = chunk
    self:play_next()
  end
end

-- ---------- время ----------
function K:on_tick()
  local now = self:clock()
  for rid, p in pairs(self.pending) do
    if now > p.deadline then
      self.pending[rid] = nil
      self.link = "нет связи"
      call(p.cb, nil, "нет связи с капсулой")
    end
  end
  if now >= (self.next_ping or 0) then
    if not self:busy() then
      if (self.link == "?" or self.link == "поиск") and self.pinged then self.link = "нет связи" end
      self.pinged = true
      self:send({ op = "ping", player = self.name })
    end
    self.next_ping = now + (self.link == "на связи" and 60 or 20)
  end
  if self.flash_msg and now > self.flash_msg.till then self.flash_msg = nil end
  for _, tab in ipairs(self.tabs) do if tab.tick then tab.tick(self) end end
  self.tick_timer = os.startTimer(1)
end

-- ---------- сообщения, подтверждение, ввод ----------
function K:flash(s, fg) self.flash_msg = { text = tostring(s), fg = fg or colors.yellow, till = self:clock() + 4 } end

function K:confirm(key, s)
  local c = self.confirming
  if c and c.key == key and self:clock() <= c.till then self.confirming = nil; return true end
  self.confirming = { key = key, till = self:clock() + 4 }
  self:flash(s or "Ещё раз — подтвердить", colors.orange)
  return false
end

-- Строка ввода внизу: Enter — cb(текст), ↑/↓ или Tab — отмена.
function K:ask(label, opts, cb)
  opts = opts or {}
  local ed = input.new({ term = self.t, x = 1, y = self.h, width = self.w, prompt = label .. ": ", max = opts.max or 100,
    history = false, prompt_fg = colors.yellow, placeholder = opts.placeholder })
  if opts.value and opts.value ~= "" then ed:set(opts.value) end
  self.prompt = { ed = ed, cb = cb }
end

function K:show(i)
  if i < 1 then i = #self.tabs elseif i > #self.tabs then i = 1 end
  self.cur, self.prompt, self.confirming = i, nil, nil
  local tab = self:tab()
  if tab.show then tab.show(self, self.st[tab.id]) end
end

function K:show_id(id)
  for i, tab in ipairs(self.tabs) do if tab.id == id then return self:show(i) end end
end

-- ---------- рисование ----------
-- Подписи вкладок: все полностью, если влезают; иначе активная полностью, остальные коротко; иначе все коротко.
function K:tab_labels()
  local labels = {}
  for i, tab in ipairs(self.tabs) do
    local b = tab.badge and tab.badge(self, self.st[tab.id]) or nil
    labels[i] = { title = tab.title .. (b and "*" or ""), short = tab.short .. (b and "*" or ""), badge = b }
  end
  local function total(pick)
    local n = -1
    for i, l in ipairs(labels) do n = n + text.len(pick(i, l)) + 1 end
    return n
  end
  local modes = {
    function(_, l) return l.title end,
    function(i, l) return i == self.cur and l.title or l.short end,
    function(_, l) return l.short end,
  }
  local pick = modes[3]
  for _, m in ipairs(modes) do
    if total(m) <= self.w then pick = m; break end
  end
  for i, l in ipairs(labels) do l.s = pick(i, l) end
  return labels
end

function K:draw_tabs()
  local w = self.w
  self:put(1, 2, (" "):rep(w), colors.white, colors.black)
  local labels = self:tab_labels()
  local x, zones = 1, {}
  for i, l in ipairs(labels) do
    local s = l.s
    local room = w - x + 1
    if room <= 0 then break end
    if text.len(s) > room then s = text.sub(s, 1, room) end
    local on = i == self.cur
    self:put(x, 2, s, on and colors.black or (l.badge or colors.lightGray), on and colors.cyan or colors.black)
    zones[#zones + 1] = { x0 = x, x1 = x + text.len(s) - 1, i = i }
    x = x + text.len(s) + 1
  end
  self.zones = zones
end

function K:draw()
  local t, w, h = self.t, self.w, self.h
  t.setCursorBlink(false)
  -- шапка
  local st = self.link
  if self:busy() then st = "запрос.." end
  local chat = self.st.chat
  if chat and chat.waiting then st = "жду ответ" end
  local stw = text.len(st)
  self:put(1, 1, (" "):rep(w), colors.white, colors.gray)
  self:put(1, 1, text.fit("КПК " .. tostring(self.name or ""), math.max(1, w - stw - 1)), colors.white, colors.gray)
  self:put(w - stw + 1, 1, st, (self.link == "нет связи") and colors.orange or colors.white, colors.gray)
  self:draw_tabs()
  -- вкладка
  local tab = self:tab()
  for y = 3, h - 1 do self:put(1, y, (" "):rep(w), colors.white, colors.black) end
  local ok, err = pcall(tab.draw, self, self.st[tab.id], 1, 3, w, h - 4)
  if not ok then self:put(1, 3, text.fit("Ошибка: " .. tostring(err), w), colors.red, colors.black) end
  -- строка h-1: сообщение или состояние вкладки
  if self.flash_msg then
    self:put(1, h - 1, text.fit(self.flash_msg.text, w, ".."), self.flash_msg.fg, colors.black)
  elseif tab.status then
    local s, fg = tab.status(self, self.st[tab.id])
    self:put(1, h - 1, text.fit(s or "", w, ".."), fg or colors.lightGray, colors.black)
  end
  -- строка h: ввод или подсказка
  if self.prompt then
    self.prompt.ed:draw()
  elseif tab.bottom then
    tab.bottom(self, self.st[tab.id])
  else
    local hs = tab.hint and tab.hint(self, self.st[tab.id]) or ""
    self:put(1, h, text.fit(hs, w, ".."), colors.gray, colors.black)
  end
end

-- ---------- события ----------
-- Любое событие -> "exit" (выйти из программы) или nil. После обработки экран перерисовывается.
function K:handle(ev, a, b, c)
  if ev == "rednet_message" then
    if c == M.PROTO then self:on_radio(a, b) end
    return self:draw()
  elseif ev == "speaker_audio_empty" then
    return self:play_next()
  elseif ev == "timer" and a == self.tick_timer then
    self:on_tick()
    return self:draw()
  elseif ev == "term_resize" then
    self.w, self.h = self.t.getSize()
    return self:draw()
  end
  if ev == "key" and (a == keys.leftShift or a == keys.rightShift) then self.shift = true end
  if ev == "key_up" and (a == keys.leftShift or a == keys.rightShift) then self.shift = false end
  if ev == "key" and a == keys.tab then
    self:show(self.cur + (self.shift and -1 or 1))
    return self:draw()
  end
  if ev == "mouse_click" and c == 2 then
    for _, z in ipairs(self.zones or {}) do
      if b >= z.x0 and b <= z.x1 then self:show(z.i); return self:draw() end
    end
    return
  end
  if self.prompt then
    local p = self.prompt
    if ev == "key" and (a == keys.up or a == keys.down) then self.prompt = nil; return self:draw() end
    local r, s = p.ed:handle(ev, a, b, c)
    if r == "submit" then
      self.prompt = nil
      call(p.cb, s)
      return self:draw()
    elseif r then
      p.ed:draw()
    end
    return
  end
  local tab = self:tab()
  if tab.key then
    local res = tab.key(self, self.st[tab.id], ev, a, b, c)
    if res == "exit" then return "exit" end
    if res then return self:draw() end
  end
end

function K:start()
  self:show(self.cur)
  self.next_ping = 0
  self:on_tick()
  self:draw()
end

return M
