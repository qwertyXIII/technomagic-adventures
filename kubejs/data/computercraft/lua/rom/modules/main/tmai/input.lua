-- tmai.input — неблокирующий однострочный редактор для экранов CC: Tweaked (вместо read()),
-- работает внутри parallel-корутин: события скармливает вызывающий код. Русский ввод — без переключателей.
--
--   local input = require("tmai.input")
--   local ed = input.new({ term = t, x = 1, y = 19, width = 51, prompt = "> ", max = 400,
--     mask = nil,            -- "*" — ввод ключа API (звёздочки, без истории)
--     history = true,        -- true | таблица-список (UTF-8), чтобы хранить историю снаружи
--     fg = colors.white, bg = colors.black, prompt_fg = colors.yellow,   -- цвета (необязательно)
--     placeholder = "Спросите Лоцмана...", placeholder_fg = colors.gray,  -- подсказка в пустой строке
--     focus = true })
--   while true do
--     local ev = { os.pullEvent() }
--     local r, txt = ed:handle(table.unpack(ev))   -- ЛЮБОЕ событие, в т.ч. timer (свой таймер редактор узнаёт сам)
--     if r == "submit" then ... txt (UTF-8) ... ; ed:draw()
--     elseif r == "changed" then ed:draw() end      -- изменился текст или курсор — перерисовать
--   end
-- Методы: ed:draw(), ed:place_cursor() (вернуть курсор после рисования чужого), ed:set(text), ed:get(),
--   ed:clear(), ed:focus(bool), ed:move(x, y, width); поле ed.layout — догадка о раскладке ("en"/"ru").
-- Клавиши: ← → Home End, Backspace, Delete, Ctrl+←/→ и Ctrl+Backspace/Delete — по словам,
--   ↑/↓ — история, Enter — "submit" (строка очищается). Мышь/касание по строке ставит курсор.
--
-- Русский ввод. CC: Tweaked 1.120 не пропускает кириллицу в событие char (StringUtil.unicodeToTerminal ->
-- -1, событие не отправляется), а key приходит с кодом физической клавиши (раскладка US). Поэтому:
--   * после key «буквенной» клавиши ЙЦУКЕН ждём char; пришёл обычный символ — это латинская раскладка;
--     пришёл "?" или ничего (таймер ~0.1 с, или следующая клавиша) — вставляем русскую букву по клавише;
--     регистр — по удерживаемому Shift (Caps Lock не отслеживается);
--   * когда раскладка уже русская (ed.layout == "ru"), буква вставляется сразу, без ожидания;
--     если следом всё же пришёл char — буква заменяется им, раскладка снова "en";
--   * Shift+3 без char -> «№»; цифры и знаки русской раскладки (Shift+2 = ", / = . и т.п.) приходят обычным char;
--   * Ctrl/Alt/Cmd + клавиша символов не вставляют (AltGr = Ctrl+Alt — пропускается).
-- Вставка из буфера (paste): CC отбрасывает кириллицу ещё на клиенте, проходит только латиница/Latin-1.
-- Внутри строка хранится байтами терминала (1 байт = 1 клетка), наружу — UTF-8 (tmai.text).

local text = require("tmai.text")

local M = {}

-- Коды клавиш GLFW (keys.* в CC: Tweaked для MC 1.16+).
local K = {
  enter = 257, numPadEnter = 335, backspace = 259, delete = 261, right = 262, left = 263, down = 264, up = 265,
  home = 268, ["end"] = 269,
}
local MODS = { [340] = "shift", [344] = "shift", [341] = "ctrl", [345] = "ctrl", [342] = "alt", [346] = "alt",
  [343] = "super", [347] = "super" }

-- Русская раскладка (ЙЦУКЕН) по физическим клавишам US. Код клавиши GLFW = ASCII-код символа US
-- (для букв — заглавной). weak — клавиша, которая в русской раскладке Windows даёт ASCII или различается
-- между ПК и Mac: для неё не вставляем заранее и не меняем догадку о раскладке.
local RU = {}
do
  local function add(us, lo, up, weak)
    RU[string.byte(us)] = { lo = lo and text.cc(lo), up = up and text.cc(up), weak = weak }
  end
  local pairs_ = {
    "qйЙ", "wцЦ", "eуУ", "rкК", "tеЕ", "yнН", "uгГ", "iшШ", "oщЩ", "pзЗ", "[хХ", "]ъЪ",
    "aфФ", "sыЫ", "dвВ", "fаА", "gпП", "hрР", "jоО", "kлЛ", "lдД", ";жЖ", "'эЭ",
    "zяЯ", "xчЧ", "cсС", "vмМ", "bиИ", "nтТ", "mьЬ", ",бБ", ".юЮ",
  }
  for _, p in ipairs(pairs_) do
    local us = p:sub(1, 1)
    local lo, up = text.sub(p, 2, 2), text.sub(p, 3, 3)
    add(us:match("%l") and us:upper() or us, lo, up)
  end
  add("`", "ё", "Ё", true)      -- ПК: ё на `
  add("\\", "ё", "Ё", true)     -- Mac «Русская»: ё на \ (на ПК там \ — придёт обычным char)
  add("/", "ё", "Ё", true)
  add("3", nil, "№")            -- Shift+3
end

local DELAY = 0.1     -- сколько ждать char после key (латинская раскладка шлёт его сразу)
local HOLD = 0.25     -- сколько помнить заранее вставленную русскую букву

local Ed = {}
Ed.__index = Ed

function M.new(o)
  o = o or {}
  local self = setmetatable({}, Ed)
  self.t = o.term or term
  self.x, self.y = o.x or 1, o.y or 1
  self.width = o.width or (self.t.getSize() - self.x + 1)
  self.prompt = o.prompt or ""
  self.max = o.max or 400
  self.mask = o.mask and text.cc(o.mask):sub(1, 1) or nil
  if self.mask == "" then self.mask = "*" end
  self.hist = nil
  if o.history and not self.mask then
    self.hist = type(o.history) == "table" and o.history or {}
  end
  self.hist_max = o.history_max or 50
  self.fg, self.bg, self.prompt_fg = o.fg, o.bg, o.prompt_fg
  self.placeholder, self.placeholder_fg = o.placeholder, o.placeholder_fg
  self.delay = o.ru_delay or DELAY
  self.buf = ""          -- строка в байтах терминала
  self.pos = 0           -- курсор: число клеток слева
  self.scroll = 0        -- сколько клеток строки скрыто слева
  self.focused = o.focus ~= false
  self.mods = {}
  self.pending = nil     -- клавиша ЙЦУКЕН, для которой ждём char
  self.layout = "en"
  return self
end

-- ---------------------------------------------------------------- правка

function Ed:_insert(s)
  local room = self.max - #self.buf
  if room <= 0 or s == "" then return false end
  if #s > room then s = s:sub(1, room) end
  self.buf = self.buf:sub(1, self.pos) .. s .. self.buf:sub(self.pos + 1)
  self.pos = self.pos + #s
  return true
end

-- Удалить клетки [a+1 .. b] и поставить курсор на a.
function Ed:_cut(a, b)
  if b <= a then return false end
  self.buf = self.buf:sub(1, a) .. self.buf:sub(b + 1)
  self.pos = a
  return true
end

local function is_word(c) return c ~= " " end

function Ed:_word_left(p)
  local b = self.buf
  while p > 0 and not is_word(b:sub(p, p)) do p = p - 1 end
  while p > 0 and is_word(b:sub(p, p)) do p = p - 1 end
  return p
end

function Ed:_word_right(p)
  local b, n = self.buf, #self.buf
  while p < n and not is_word(b:sub(p + 1, p + 1)) do p = p + 1 end
  while p < n and is_word(b:sub(p + 1, p + 1)) do p = p + 1 end
  return p
end

local function cancel(id)
  if id and os.cancelTimer then os.cancelTimer(id) end
end

-- Разрешить ожидание: char так и не пришёл -> русская раскладка.
function Ed:_settle()
  local p = self.pending
  if not p then return nil end
  self.pending = nil
  cancel(p.timer)
  if p.early then return nil end
  if not p.weak then self.layout = "ru" end
  return self:_insert(p.ch) and "changed" or nil
end

-- ---------------------------------------------------------------- события

function Ed:_key(k)
  local res = self:_settle()
  local m = self.mods
  local ctrl = m.ctrl and not m.alt
  if m.super or (m.alt and not m.ctrl) then return res end
  local ru = RU[k]
  if ru and not ctrl and not m.alt then
    local ch = m.shift and ru.up or ru.lo
    if ch then
      if self.layout == "ru" and not ru.weak then
        -- русская раскладка: вставляем сразу; если придёт char — заменим
        local at = self.pos
        local ok = self:_insert(ch)
        self.pending = { early = true, at = at, ok = ok, timer = os.startTimer(HOLD) }
        return ok and "changed" or res
      end
      self.pending = { ch = ch, weak = ru.weak, timer = os.startTimer(self.delay) }
    end
    return res
  end
  local n = #self.buf
  if k == K.enter or k == K.numPadEnter then
    return self:_submit()
  elseif k == K.backspace then
    if self.pos == 0 then return res end
    self:_cut(ctrl and self:_word_left(self.pos) or self.pos - 1, self.pos)
  elseif k == K.delete then
    if self.pos >= n then return res end
    self:_cut(self.pos, ctrl and self:_word_right(self.pos) or self.pos + 1)
  elseif k == K.left then
    if self.pos == 0 then return res end
    self.pos = ctrl and self:_word_left(self.pos) or self.pos - 1
  elseif k == K.right then
    if self.pos >= n then return res end
    self.pos = ctrl and self:_word_right(self.pos) or self.pos + 1
  elseif k == K.home then
    if self.pos == 0 then return res end
    self.pos = 0
  elseif k == K["end"] then
    if self.pos == n then return res end
    self.pos = n
  elseif k == K.up or k == K.down then
    return self:_history(k == K.up and -1 or 1) or res
  else
    return res
  end
  return "changed"
end

function Ed:_char(c)
  local p = self.pending
  if p then
    self.pending = nil
    cancel(p.timer)
    if c == "?" then                -- кириллица, превращённая в "?" (другие версии CC)
      if p.early then return nil end
      if not p.weak then self.layout = "ru" end
      return self:_insert(p.ch) and "changed" or nil
    end
    local cut = false
    if p.early then
      self.layout = "en"
      if p.ok then cut = self:_cut(p.at, p.at + 1) end   -- убрать заранее вставленную русскую букву
    end
    return (self:_insert(c) or cut) and "changed" or nil
  end
  local m = self.mods
  if m.super or (m.ctrl and not m.alt) or (m.alt and not m.ctrl) then return nil end
  return self:_insert(c) and "changed" or nil
end

function Ed:_paste(s)
  local res = self:_settle()
  s = tostring(s or ""):gsub("[\1-\31]", " ")
  return self:_insert(s) and "changed" or res
end

function Ed:_submit()
  local s = text.utf8(self.buf)
  local h = self.hist
  if h and s:find("[^ ]") and h[#h] ~= s then
    h[#h + 1] = s
    while #h > self.hist_max do table.remove(h, 1) end
  end
  self.hidx, self.draft = nil, nil
  self.buf, self.pos, self.scroll = "", 0, 0
  return "submit", s
end

function Ed:_history(dir)
  local h = self.hist
  if not h or #h == 0 then return nil end
  local i = self.hidx
  if dir < 0 then
    if i == nil then self.draft = self.buf; i = #h
    elseif i > 1 then i = i - 1
    else return nil end
    self.buf = text.cc(h[i])
  else
    if i == nil then return nil end
    if i < #h then i = i + 1; self.buf = text.cc(h[i])
    else i = nil; self.buf = self.draft or "" end
  end
  self.hidx = i
  self.buf = self.buf:sub(1, self.max)
  self.pos = #self.buf
  return "changed"
end

-- Скормить любое событие. -> "submit", текст (UTF-8) | "changed" | nil
function Ed:handle(ev, a, b, c)
  if ev == "timer" then
    local p = self.pending
    if p and a == p.timer then
      p.timer = nil
      return self:_settle()
    end
    return nil
  elseif ev == "key" then
    if MODS[a] then self.mods[MODS[a]] = true; return nil end
    if not self.focused then return nil end
    return self:_key(a)
  elseif ev == "key_up" then
    if MODS[a] then self.mods[MODS[a]] = nil end
    return nil
  end
  if not self.focused then return nil end
  if ev == "char" then
    return self:_char(a)
  elseif ev == "paste" then
    return self:_paste(a)
  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x0 = self.x + text.len(self.prompt)
    if c == self.y and b >= x0 and b < self.x + self.width then
      local res = self:_settle()
      local p = math.min(#self.buf, self.scroll + b - x0)
      if p == self.pos then return res end
      self.pos = p
      return "changed"
    end
  end
  return nil
end

-- ---------------------------------------------------------------- состояние

function Ed:get()
  return text.utf8(self.buf)
end

function Ed:set(s)
  self.pending = nil
  self.hidx, self.draft = nil, nil
  self.buf = text.cc((tostring(s or ""):gsub("[\r\n]", " "))):sub(1, self.max)
  self.pos = #self.buf
end

function Ed:clear()
  self:set("")
end

function Ed:focus(on)
  self.focused = on and true or false
  if not self.focused then
    if self.pending then cancel(self.pending.timer); self.pending = nil end
    self.t.setCursorBlink(false)
  end
end

function Ed:move(x, y, width)
  self.x, self.y = x or self.x, y or self.y
  self.width = width or self.width
end

-- ---------------------------------------------------------------- рисование

function Ed:_avail()
  return math.max(1, self.width - text.len(self.prompt))
end

function Ed:_fix_scroll()
  local avail, n = self:_avail(), #self.buf
  if self.pos < self.scroll then self.scroll = self.pos end
  if self.pos > self.scroll + avail - 1 then self.scroll = self.pos - avail + 1 end
  local most = math.max(0, n - avail + 1)    -- не прокручивать дальше, чем нужно (+1 клетка под курсор)
  if self.scroll > most then self.scroll = math.max(most, self.pos - avail + 1, 0) end
end

function Ed:draw()
  local t = self.t
  self:_fix_scroll()
  local avail = self:_avail()
  t.setCursorPos(self.x, self.y)
  if self.bg then t.setBackgroundColor(self.bg) end
  if self.prompt ~= "" then
    if self.prompt_fg then t.setTextColor(self.prompt_fg) elseif self.fg then t.setTextColor(self.fg) end
    t.write(text.cc(self.prompt):sub(1, self.width))
  end
  local vis
  if self.buf == "" and self.placeholder then
    if self.placeholder_fg then t.setTextColor(self.placeholder_fg) elseif self.fg then t.setTextColor(self.fg) end
    vis = text.cc(self.placeholder):sub(1, avail)
  else
    if self.fg then t.setTextColor(self.fg) end
    vis = self.buf:sub(self.scroll + 1, self.scroll + avail)
    if self.mask then vis = string.rep(self.mask, #vis) end
  end
  t.write(vis .. string.rep(" ", avail - #vis))
  if self.focused then self:place_cursor() end
end

-- Поставить мигающий курсор на место ввода (после того как программа рисовала что-то ещё).
function Ed:place_cursor()
  local t = self.t
  self:_fix_scroll()
  t.setCursorPos(self.x + text.len(self.prompt) + self.pos - self.scroll, self.y)
  if self.fg then t.setTextColor(self.fg) end      -- курсор CC рисуется текущим цветом текста
  t.setCursorBlink(true)
end

return M
