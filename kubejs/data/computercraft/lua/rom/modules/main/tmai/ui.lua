-- tmai.ui — экраны ЛОЦМАНа. Говорят с ИИ только здесь (терминал компьютера) и с КПК — не через игровой чат.
--
-- Терминал (ПКМ по компьютеру TM-AI), 51×19:
--   строка 1 — состояние коротко; строка 2 — вкладки (щелчок мышью, Tab / Shift+Tab);
--   Чат — лента разговора и строка ввода внизу (имя говорящего слева: определяется детектором игроков,
--         щелчок по имени — сменить); Задания — поручения ЛОЦМАНа (Enter — взять, Delete — отменить);
--   Память — восстановленные записи, находки, заметки (Enter — читать); Стройка — планы прораба;
--   Устройства — что подключено и где Ящик памяти (Enter на инвентаре — сделать Ящиком памяти);
--   Настройки — ключ, адреса, модели… (Enter — изменить, ввод внизу; ключи — звёздочками).
--   PgUp/PgDn или колесо мыши — листать.
-- Монитор (продвинутый, от 2×1 блоков): левая половина — состояние ИИ, правая — вкладки касанием
--   (Чат, Задания, Память, Стройка); касание верхней/нижней половины текста — листать.
--
-- Модуль ничего не ждёт (не уступает управление): данные готовит app.lua в M.data, действия игрока
-- возвращаются списком { kind=…, … } — их выполняет app.lua.

local text = require("tmai.text")
local input = require("tmai.input")
local feed = require("tmai.feed")
local config = require("tmai.config")

local M = {}

M.TABS = {
  { id = "chat", title = "Чат", short = "Чат" },
  { id = "quests", title = "Задания", short = "Зад" },
  { id = "memory", title = "Память", short = "Пам" },
  { id = "build", title = "Стройка", short = "Стр" },
  { id = "devices", title = "Устройства", short = "Устр" },
  { id = "settings", title = "Настройки", short = "Наст" },
}
local MON_TABS = { "chat", "quests", "memory", "build" }
local MON_FOLLOW = false   -- ИИ показал план: монитор переключится на «Стройку»

-- Данные от app.lua: status, quests {active, available}, memory {rows}, devices {rows}, speaker, busy, build
M.data = { status = {}, quests = {}, memory = {}, devices = {}, speaker = "Экипаж", busy = false }
M.reader = nil      -- function(row) -> заголовок, текст (чтение записи памяти); задаёт app.lua
M.build = nil       -- модуль tmai.build (если есть)

local log = {}      -- служебные строки (ошибки настройки и т.п.) — во вкладке «Устройства»
function M.log_line(s)
  log[#log + 1] = textutils.formatTime(os.time(), true) .. " " .. tostring(s)
  while #log > 20 do table.remove(log, 1) end
end

-- ---------- рисование ----------
local function put(t, x, y, s, fg, bg)
  t.setCursorPos(x, y)
  if fg then t.setTextColor(fg) end
  if bg then t.setBackgroundColor(bg) end
  t.write(text.cc(s))
end

local function bar(t, x, y, w, bg)
  t.setCursorPos(x, y)
  t.setBackgroundColor(bg)
  t.write((" "):rep(math.max(0, w)))
end

local function clear_area(t, x, y, w, h, bg)
  for yy = y, y + h - 1 do bar(t, x, yy, w, bg or colors.black) end
end

local function is_color(t)
  local ok, c = pcall(t.isColor)
  return ok and c
end

local NAME_FG = { user = colors.yellow, ai = colors.cyan, sys = colors.lightGray, warn = colors.orange }
local TEXT_FG = { user = colors.white, ai = colors.white, sys = colors.lightGray, warn = colors.orange }

-- Лента чата в строки нужной ширины (с кэшем по версии ленты и ширине).
local wrap_cache = {}
local function feed_lines(width)
  local c = wrap_cache[width]
  if c and c.version == feed.version then return c.lines end
  local lines = {}
  for _, it in ipairs(feed.items()) do
    local who = it.who and it.who ~= "" and it.who or (it.kind == "sys" and "Капсула" or "?")
    local head = who .. ": "
    local wrapped = text.wrap(head .. text.clean(it.text), width)
    for i, l in ipairs(wrapped) do
      lines[#lines + 1] = { s = l, kind = it.kind, head = i == 1 and text.len(head) or 0 }
    end
  end
  wrap_cache[width] = { version = feed.version, lines = lines }
  return lines
end

-- Нарисовать ленту в прямоугольнике; scroll — сколько строк от низа пропущено. Возвращает число строк.
local function draw_feed(t, x, y, w, h, scroll, busy)
  local lines = feed_lines(w)
  local rows = h - (busy and 1 or 0)
  local last = #lines - (scroll or 0)
  local first = math.max(1, last - rows + 1)
  clear_area(t, x, y, w, h)
  local yy = y + rows - (last - first + 1)
  for i = first, last do
    local l = lines[i]
    if l.head > 0 then
      put(t, x, yy, text.sub(l.s, 1, l.head), NAME_FG[l.kind] or colors.white, colors.black)
      put(t, x + l.head, yy, text.sub(l.s, l.head + 1), TEXT_FG[l.kind] or colors.white)
    else
      put(t, x, yy, l.s, TEXT_FG[l.kind] or colors.white, colors.black)
    end
    yy = yy + 1
  end
  if busy then
    local dots = ("..."):sub(1, math.floor(os.clock() * 2) % 3 + 1)
    put(t, x, y + h - 1, text.fit("ЛОЦМАН думает" .. dots, w), colors.gray, colors.black)
  end
  if #lines == 0 then put(t, x, y, text.fit("Пока тихо. Задайте вопрос.", w), colors.gray, colors.black) end
  return #lines
end

-- ---------- состояние ----------
local function power_text(p)
  if not p or not p.energy then return "нет ядра", colors.red end
  if p.far then return "ядро не рядом", colors.red end
  return p.pct .. "%", p.ok and colors.lime or colors.red
end

local function status_rows(st)
  local p = st.power or {}
  local pw, pfg = power_text(p)
  local rows = {
    { "Энергия", pw, pfg },
    { "Нейросеть", st.llm == "ok" and "на связи" or (st.llm == "error" and "сбой" or (st.llm_ready and "ждёт" or "не настр.")),
      st.llm == "ok" and colors.lime or (st.llm == "error" and colors.orange or colors.gray) },
    { "Поиск", st.search or "по словам", colors.white },
    { "МЭ-сеть", st.me and "в сети" or "нет", st.me and colors.lime or colors.gray },
    { "Модуль", st.nav and ("ремонт " .. (st.repair or 0) .. "/4") or "нет связи", st.nav and colors.lime or colors.gray },
    { "Радио", st.radio or "?", colors.white },
    { "Очередь", tostring(st.queue or 0), (st.queue or 0) > 0 and colors.yellow or colors.white },
  }
  return rows, p
end

-- ---------- терминал: состояние вкладок ----------
local T = { tab = "chat", scroll = {}, sel = {}, edit = nil, read = nil, shift = false }
local ed, sed            -- строка чата и строка правки настройки

local function term_size() return term.getSize() end

local function tab_index(id)
  for i, tb in ipairs(M.TABS) do if tb.id == id then return i end end
  return 1
end

local function ensure_editors()
  local w, h = term_size()
  if not ed then
    ed = input.new({ term = term, x = 1, y = h, width = w, prompt = "> ", max = 400, history = true,
      prompt_fg = colors.yellow, placeholder = "Спросите Лоцмана… (Enter — отправить)" })
  end
  local name = M.data.speaker or "Экипаж"
  if text.len(name) > 12 then name = text.sub(name, 1, 12) end
  local prompt = name .. "> "
  local pw = text.len(prompt)
  ed.prompt = prompt
  ed:move(1, h, w)
  T.prompt_w = pw
end

-- Список строк вкладки-списка (задания, память, устройства, настройки): { text=, fg=, header=bool, row=… }
local function list_rows(tab)
  local out = {}
  if tab == "quests" then
    local q = M.data.quests or {}
    out[#out + 1] = { text = "Активное поручение", header = true }
    if q.active then
      local a = q.active
      out[#out + 1] = { text = "«" .. tostring(a.title) .. "» — " .. tostring(a.progress or "в работе"), fg = colors.yellow }
      if a.player then out[#out + 1] = { text = "  взял: " .. a.player, fg = colors.lightGray } end
      if a.coords then out[#out + 1] = { text = string.format("  цель: X %d, Z %d (%s)", a.coords.x or 0, a.coords.z or 0, tostring(a.coords.dim or "")), fg = colors.lightGray } end
    else
      out[#out + 1] = { text = "нет — выберите ниже и нажмите Enter", fg = colors.gray }
    end
    out[#out + 1] = { text = "Доступные", header = true }
    for _, it in ipairs(q.available or {}) do
      out[#out + 1] = { text = "«" .. tostring(it.title) .. "»", fg = colors.white, row = { kind = "quest", id = it.id, hint = it.hint } }
    end
    if #(q.available or {}) == 0 then out[#out + 1] = { text = "пока нет (появятся по мере ремонта ядра)", fg = colors.gray } end
  elseif tab == "memory" then
    for _, r in ipairs(M.data.memory or {}) do out[#out + 1] = r end
  elseif tab == "devices" then
    for _, r in ipairs(M.data.devices or {}) do out[#out + 1] = r end
    if #log > 0 then
      out[#out + 1] = { text = "Журнал", header = true }
      for i = math.max(1, #log - 6), #log do out[#out + 1] = { text = log[i], fg = colors.gray } end
    end
  elseif tab == "settings" then
    for _, d in ipairs(config.list()) do
      if d.group then out[#out + 1] = { text = d.group, header = true }
      else
        local v = d.value
        if d.secret then v = (v and v ~= "") and ("•••• " .. tostring(v):sub(-4)) or "(не задан)"
        elseif type(v) == "boolean" then v = v and "да" or "нет"
        else v = tostring(v) end
        out[#out + 1] = { text = d.key, value = v, fg = colors.white, row = { kind = "setting", def = d } }
      end
    end
  end
  return out
end

local function selectable(rows, i) return rows[i] and rows[i].row ~= nil end

local function fix_sel(tab, rows)
  local s = T.sel[tab] or 1
  if not selectable(rows, s) then
    for i = 1, #rows do if selectable(rows, i) then s = i; break end end
  end
  T.sel[tab] = s
  return s
end

local function move_sel(tab, dir)
  local rows = list_rows(tab)
  local s = fix_sel(tab, rows)
  local i = s + dir
  while rows[i] and not selectable(rows, i) do i = i + dir end
  if selectable(rows, i) then T.sel[tab] = i end
end

-- Нижняя строка-подсказка для вкладки.
local function hint_for(tab, sel_row)
  if T.read then return "Backspace/Enter — назад · PgUp/PgDn — листать" end
  if T.edit then return "Enter — сохранить · ↑/↓ — отмена" end
  if tab == "chat" then return "Tab — вкладки · PgUp/PgDn — листать · «да КОД» — подтвердить" end
  if tab == "quests" then return "↑↓ — выбор · Enter — взять · Delete — отменить активное" end
  if tab == "memory" then return "↑↓ — выбор · Enter — читать" end
  if tab == "devices" then return sel_row and sel_row.action and "Enter — " .. sel_row.action.label or "↑↓ — выбор" end
  if tab == "settings" then return "↑↓ — выбор · Enter — изменить" end
  if tab == "build" then return "↑↓ — план · ←→ — слой · Enter — на монитор" end
  return ""
end

local function draw_list(t, x, y, w, h, tab)
  local rows = list_rows(tab)
  local sel = fix_sel(tab, rows)
  -- прокрутка: держим выбранную строку в окне
  local top = T.scroll[tab] or 1
  if sel < top then top = sel end
  if sel > top + h - 1 then top = sel - h + 1 end
  top = math.max(1, math.min(top, math.max(1, #rows - h + 1)))
  T.scroll[tab] = top
  clear_area(t, x, y, w, h)
  for i = top, math.min(#rows, top + h - 1) do
    local r = rows[i]
    local yy = y + i - top
    if r.header then
      put(t, x, yy, text.fit(r.text, w), colors.cyan, colors.black)
    else
      local cur = i == sel
      local bg = cur and colors.gray or colors.black
      local line = (cur and "> " or "  ") .. r.text
      if r.value then
        local vw = math.min(text.len(r.value), math.floor(w / 2))
        line = text.fit(line, w - vw - 1) .. " " .. text.fit(r.value, vw)
      end
      put(t, x, yy, text.fit(line, w), r.fg or colors.white, bg)
    end
  end
  return rows[sel]
end

local function draw_reader(t, x, y, w, h)
  local rd = T.read
  local lines = rd.lines
  if not lines or rd.w ~= w then
    lines = text.wrap(rd.body, w); rd.lines = lines; rd.w = w
  end
  clear_area(t, x, y, w, h)
  put(t, x, y, text.fit(rd.title, w), colors.cyan, colors.black)
  local top = math.max(1, math.min(rd.top or 1, math.max(1, #lines - (h - 2))))
  rd.top = top
  for i = 0, h - 2 do
    local l = lines[top + i]
    if l then put(t, x, y + 1 + i, l, colors.white, colors.black) end
  end
end

-- Текущий план для вкладки «Стройка»: выбранный вручную, иначе выбранный ИИ (build_show), иначе последний.
local function build_current()
  local b = M.build
  local plans = b.list_plans() or {}
  local sid, slayer = b.selected()
  local id = T.build_id or sid or (plans[#plans] and plans[#plans].id)
  local layers = 1
  for _, p in ipairs(plans) do if p.id == id then layers = p.layers or 1 end end
  local layer = T.build_layer or (id == sid and slayer) or 1
  return id, math.max(1, math.min(layer, layers)), plans, layers
end

local function draw_build(t, x, y, w, h)
  clear_area(t, x, y, w, h)
  local b = M.build
  if not b then
    put(t, x, y, text.fit("Прораб не подключён.", w), colors.gray, colors.black)
    return
  end
  local ok, err = pcall(function()
    local id, layer = build_current()
    local st = b.status_lines and b.status_lines() or {}
    local rows = h - (#st > 0 and 1 or 0)
    b.render(window.create(t, x, y, w, rows, true), id, layer, {})
    if #st > 0 then put(t, x, y + h - 1, text.fit(st[1], w), colors.lightGray, colors.black) end
  end)
  if not ok then put(t, x, y, text.fit("Ошибка экрана стройки: " .. tostring(err), w), colors.red, colors.black) end
end

-- ИИ показал план (build_show / новый план): терминал и монитор переходят к нему.
function M.follow_build(id, layer)
  T.build_id, T.build_layer = tonumber(id), tonumber(layer)
  MON_FOLLOW = true
end

function M.draw_term()
  local t = term
  local w, h = term_size()
  ensure_editors()
  t.setCursorBlink(false)
  local st = M.data.status or {}
  -- строка 1: имя и коротко о состоянии
  bar(t, 1, 1, w, colors.gray)
  local pw, pfg = power_text(st.power)
  put(t, 1, 1, " " .. (st.name or "ЛОЦМАН"), colors.white, colors.gray)
  local right = "энергия " .. pw .. "  " .. textutils.formatTime(os.time(), true) .. " "
  put(t, w - text.len(right) + 1, 1, right, colors.white, colors.gray)
  -- строка 2: вкладки
  bar(t, 1, 2, w, colors.black)
  local xx = 1
  T.tab_x = {}
  local full = 0
  for _, tb in ipairs(M.TABS) do full = full + text.len(tb.title) + 1 end
  for _, tb in ipairs(M.TABS) do
    local label = full <= w and tb.title or tb.short
    local active = tb.id == T.tab
    put(t, xx + 1, 2, label, active and colors.black or colors.lightGray, active and colors.cyan or colors.black)
    T.tab_x[#T.tab_x + 1] = { x0 = xx, x1 = xx + text.len(label), id = tb.id }
    xx = xx + text.len(label) + 1
  end
  -- содержимое: строки 3..h-2 (чат — до h-1)
  local cy, ch = 3, h - 4
  local sel_row
  if T.read then
    draw_reader(t, 1, cy, w, ch + 1)
  elseif T.tab == "chat" then
    draw_feed(t, 1, cy, w, ch + 1, T.scroll.chat or 0, M.data.busy)
  elseif T.tab == "build" then
    draw_build(t, 1, cy, w, ch + 1)
  else
    sel_row = draw_list(t, 1, cy, w, ch, T.tab)
    -- под списком — описание выбранного
    local desc = ""
    if sel_row and sel_row.row then
      if sel_row.row.kind == "setting" then desc = sel_row.row.def.desc or ""
      elseif sel_row.row.kind == "quest" then desc = sel_row.row.hint or ""
      elseif sel_row.desc then desc = sel_row.desc end
    end
    put(t, 1, h - 1, text.fit(desc, w), colors.lightGray, colors.black)
  end
  -- последняя строка: ввод или подсказка
  if T.edit then
    sed:draw()
  elseif T.tab == "chat" and not T.read then
    put(t, 1, h - 1, text.fit(hint_for("chat"), w), colors.gray, colors.black)
    ed:draw()
  else
    put(t, 1, h, text.fit(hint_for(T.tab, sel_row), w), colors.gray, colors.black)
  end
end

-- ---------- терминал: ввод ----------
local function start_edit(def)
  local w, h = term_size()
  if def.type == "boolean" then
    return { kind = "setting", key = def.key, value = not def.value }
  end
  T.edit = def
  sed = input.new({ term = term, x = 1, y = h, width = w, prompt = def.key .. "= ", max = 300, history = false,
    mask = def.secret and "*" or nil, placeholder = def.secret and "вставьте ключ (Ctrl+V)" or "" })
  if not def.secret then sed:set(tostring(def.value == nil and "" or def.value)) end
  return nil
end

local function activate(tab, rows)
  local r = rows[T.sel[tab] or 0]
  if not r then return nil end
  if r.action then return r.action end
  if not r.row then return nil end
  if r.row.kind == "setting" then return start_edit(r.row.def)
  elseif r.row.kind == "quest" then return { kind = "quest_accept", id = r.row.id }
  elseif r.row.kind == "read" and M.reader then
    local title, body = M.reader(r.row)
    T.read = { title = title or r.text, body = body or "(пусто)", top = 1 }
  end
  return nil
end

local function switch_tab(dir)
  local i = tab_index(T.tab) + dir
  if i < 1 then i = #M.TABS elseif i > #M.TABS then i = 1 end
  T.tab = M.TABS[i].id
  T.read, T.edit = nil, nil
end

-- Событие терминала -> список действий, нужна ли перерисовка (M.draw_term()).
function M.handle_term(ev, a, b, c)
  local acts, dirty = M._handle_term(ev, a, b, c)
  return acts, dirty or ev ~= "timer" or #acts > 0
end


function M._handle_term(ev, a, b, c)
  local acts = {}
  local w, h = term_size()
  if ev == "key" and (a == keys.leftShift or a == keys.rightShift) then T.shift = true end
  if ev == "key_up" and (a == keys.leftShift or a == keys.rightShift) then T.shift = false end
  ensure_editors()
  -- правка настройки
  if T.edit then
    if ev == "key" and (a == keys.up or a == keys.down or a == keys.tab) then T.edit = nil; return acts end
    local r, txt = sed:handle(ev, a, b, c)
    local edited = r ~= nil
    if r == "submit" then
      acts[#acts + 1] = { kind = "setting", key = T.edit.key, value = txt }
      T.edit = nil
    end
    return acts, edited
  end
  if ev == "key" and a == keys.tab then switch_tab(T.shift and -1 or 1); return acts end
  if ev == "mouse_click" and b and c == 2 then
    for _, tx in ipairs(T.tab_x or {}) do
      if b >= tx.x0 and b <= tx.x1 then T.tab = tx.id; T.read, T.edit = nil, nil; return acts end
    end
  end
  -- чтение записи
  if T.read then
    if ev == "key" and (a == keys.backspace or a == keys.enter) then T.read = nil
    elseif (ev == "key" and a == keys.pageUp) or (ev == "mouse_scroll" and a < 0) then T.read.top = (T.read.top or 1) - (ev == "key" and h - 5 or 2)
    elseif (ev == "key" and a == keys.pageDown) or (ev == "mouse_scroll" and a > 0) then T.read.top = (T.read.top or 1) + (ev == "key" and h - 5 or 2)
    elseif ev == "key" and a == keys.up then T.read.top = (T.read.top or 1) - 1
    elseif ev == "key" and a == keys.down then T.read.top = (T.read.top or 1) + 1 end
    return acts
  end
  if T.tab == "chat" then
    local page = h - 5
    if (ev == "key" and a == keys.pageUp) or (ev == "mouse_scroll" and a < 0) then
      T.scroll.chat = math.min((T.scroll.chat or 0) + (ev == "key" and page or 2), math.max(0, #feed_lines(w) - 3))
      return acts
    elseif (ev == "key" and a == keys.pageDown) or (ev == "mouse_scroll" and a > 0) then
      T.scroll.chat = math.max(0, (T.scroll.chat or 0) - (ev == "key" and page or 2))
      return acts
    end
    if ev == "mouse_click" and c == h and b <= (T.prompt_w or 0) then
      acts[#acts + 1] = { kind = "cycle_speaker" }
      return acts
    end
    local r, txt = ed:handle(ev, a, b, c)
    if r == "submit" and txt and txt:match("%S") then
      T.scroll.chat = 0
      acts[#acts + 1] = { kind = "say", text = txt }
    end
    return acts, r ~= nil
  end
  if T.tab == "build" then
    if not M.build then return acts end
    local id, layer, plans, layers = build_current()
    if ev == "key" and (a == keys.left or a == keys.right) then
      T.build_id = id
      T.build_layer = math.max(1, math.min(layers, layer + (a == keys.left and -1 or 1)))
    elseif ev == "key" and (a == keys.up or a == keys.down) then
      for i, p in ipairs(plans) do
        if p.id == id then
          local j = i + (a == keys.up and -1 or 1)
          if plans[j] then T.build_id = plans[j].id; T.build_layer = 1 end
          break
        end
      end
    elseif ev == "key" and a == keys.enter and id then
      acts[#acts + 1] = { kind = "build_show", id = id, layer = layer }
    end
    return acts
  end
  -- вкладки-списки
  local rows = list_rows(T.tab)
  fix_sel(T.tab, rows)
  if ev == "key" and a == keys.up then move_sel(T.tab, -1)
  elseif ev == "key" and a == keys.down then move_sel(T.tab, 1)
  elseif ev == "key" and a == keys.pageUp then for _ = 1, h - 6 do move_sel(T.tab, -1) end
  elseif ev == "key" and a == keys.pageDown then for _ = 1, h - 6 do move_sel(T.tab, 1) end
  elseif ev == "mouse_scroll" then move_sel(T.tab, a)
  elseif ev == "key" and a == keys.enter then
    local act = activate(T.tab, rows)
    if act then acts[#acts + 1] = act end
  elseif ev == "key" and a == keys.delete and T.tab == "quests" then
    acts[#acts + 1] = { kind = "quest_abandon" }
  elseif ev == "mouse_click" and c >= 3 and c <= h - 2 then
    local i = (T.scroll[T.tab] or 1) + c - 3
    if selectable(rows, i) then
      if T.sel[T.tab] == i then
        local act = activate(T.tab, rows)
        if act then acts[#acts + 1] = act end
      else
        T.sel[T.tab] = i
      end
    end
  end
  return acts
end

function M.show_tab(id)
  T.tab = id; T.read, T.edit = nil, nil
end

-- ---------- монитор ----------
local MON = { tab = "chat", scroll = 0, name = nil }

-- Монитор: заданный в настройках, иначе самый большой (выбор запоминается до смены периферии).
local function pick_monitor(cfg_name, scale)
  if cfg_name and cfg_name ~= "" and peripheral.hasType(cfg_name, "monitor") then return peripheral.wrap(cfg_name), cfg_name end
  if MON.name and peripheral.hasType(MON.name, "monitor") then return peripheral.wrap(MON.name), MON.name end
  local best, bname, barea = nil, nil, -1
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "monitor") then
      local m = peripheral.wrap(n)
      local ok, mw, mh = pcall(function() m.setTextScale(scale); return m.getSize() end)
      if ok and mw * mh > barea then best, bname, barea = m, n, mw * mh end
    end
  end
  return best, bname
end

-- Сменилась периферия: выбрать монитор заново.
function M.reset_monitor() MON.name = nil end

function M.monitor_name() return MON.name end

local function draw_status_panel(t, x, y, w, h, st)
  clear_area(t, x, y, w, h, colors.black)
  put(t, x, y, text.fit(st.name or "ЛОЦМАН", w), colors.cyan, colors.black)
  local rows, p = status_rows(st)
  local yy = y + 1
  for i, r in ipairs(rows) do
    if yy > y + h - 2 then break end
    local label = r[1]
    local val = tostring(r[2])
    local gap = w - text.len(label) - text.len(val)
    if gap < 1 then label = text.sub(label, 1, math.max(1, w - text.len(val) - 1)); gap = 1 end
    put(t, x, yy, label .. (" "):rep(gap), colors.lightGray, colors.black)
    put(t, x + text.len(label) + gap, yy, val, r[3] or colors.white)
    yy = yy + 1
    if i == 1 and p and p.energy and yy <= y + h - 2 then   -- полоска заряда
      local fillw = math.floor((w) * math.max(0, math.min(100, p.pct or 0)) / 100 + 0.5)
      bar(t, x, yy, fillw, p.ok and colors.green or colors.red)
      bar(t, x + fillw, yy, w - fillw, colors.gray)
      yy = yy + 1
    end
  end
  put(t, x, y + h - 1, text.fit(textutils.formatTime(os.time(), true) .. " · день " .. os.day(), w), colors.gray, colors.black)
end

local function draw_mon_list(t, x, y, w, h, tab)
  local rows = list_rows(tab)
  local lines = {}
  for _, r in ipairs(rows) do
    local s = r.header and r.text or ((r.row and "• " or "  ") .. r.text)
    for _, l in ipairs(text.wrap(s, w)) do lines[#lines + 1] = { s = l, fg = r.header and colors.cyan or (r.fg or colors.white) } end
  end
  local top = math.max(1, math.min(MON.scroll + 1, math.max(1, #lines - h + 1)))
  MON.scroll = top - 1
  clear_area(t, x, y, w, h)
  for i = 0, h - 1 do
    local l = lines[top + i]
    if l then put(t, x, y + i, l.s, l.fg, colors.black) end
  end
end

function M.draw_monitor(cfg)
  local scale = math.max(0.5, math.min(5, (cfg and tonumber(cfg.monitor_scale)) or 0.5))
  local mon, name = pick_monitor(cfg and cfg.monitor, scale)
  MON.name = name
  if not mon then return false end
  if MON.scale ~= scale or MON.scaled ~= name then pcall(mon.setTextScale, scale); MON.scale, MON.scaled = scale, name end
  local w, h = mon.getSize()
  mon.setCursorBlink(false)
  local st = M.data.status or {}
  if w < 30 or h < 8 then              -- старый монитор 1×1: только состояние и подсказка
    draw_status_panel(mon, 1, 1, w, h, st)
    put(mon, 1, h, text.fit("нужен монитор 2×1", w), colors.orange, colors.black)
    return true
  end
  if MON_FOLLOW then MON.tab = "build"; MON.scroll = 0; MON_FOLLOW = false end
  local lw = math.floor(w / 2)
  draw_status_panel(mon, 1, 1, lw - 1, h, st)
  for yy = 1, h do bar(mon, lw, yy, 1, colors.gray) end
  local rx, rw = lw + 1, w - lw
  -- вкладки
  bar(mon, rx, 1, rw, colors.black)
  local xx = rx
  MON.tab_x = {}
  for _, id in ipairs(MON_TABS) do
    local tb = M.TABS[tab_index(id)]
    local label = (rw >= 34 and tb.title or tb.short)
    local active = id == MON.tab
    put(mon, xx, 1, label, active and colors.black or colors.lightGray, active and colors.cyan or colors.black)
    MON.tab_x[#MON.tab_x + 1] = { x0 = xx, x1 = xx + text.len(label) - 1, id = id }
    xx = xx + text.len(label) + 1
  end
  if MON.tab == "chat" then
    draw_feed(mon, rx, 2, rw, h - 1, MON.scroll, M.data.busy)
  elseif MON.tab == "build" then
    draw_build(mon, rx, 2, rw, h - 1)
  else
    draw_mon_list(mon, rx, 2, rw, h - 1, MON.tab)
  end
  return true
end

-- Касание монитора: вкладки сверху, листание — верхняя/нижняя половина текста.
function M.handle_touch(side, x, y)
  if side ~= MON.name then return end
  if y == 1 then
    for _, tx in ipairs(MON.tab_x or {}) do
      if x >= tx.x0 and x <= tx.x1 then MON.tab = tx.id; MON.scroll = 0; return end
    end
    return
  end
  local mon = peripheral.wrap(side)
  local _, h = mon.getSize()
  local up = y < (h + 1) / 2
  if MON.tab == "chat" then
    MON.scroll = math.max(0, MON.scroll + (up and 3 or -3))
  else
    MON.scroll = math.max(0, MON.scroll + (up and -3 or 3))
  end
end

-- Показать вкладку на мониторе (например, «выведи на экран план 3»).
function M.monitor_tab(id)
  MON.tab = id; MON.scroll = 0
end

return M
