-- tmai.ui — экраны ЛОЦМАНа. Говорят с ИИ только здесь (терминал компьютера) и с КПК — не через игровой чат.
--
-- Терминал (ПКМ по компьютеру TM-AI), 51×19:
--   строка 1 — состояние коротко; строка 2 — вкладки (щелчок мышью, Tab / Shift+Tab; не влезают — листаются);
--   Главная — тревоги и все приложения (Enter — открыть; начали печатать — переход в чат);
--   приложения (tmai.apps: модули tmai/apps/*.lua) — свои вкладки между встроенными;
--   Чат — лента разговора и строка ввода внизу (имя говорящего слева: определяется детектором игроков,
--         щелчок по имени — сменить); Задания — поручения ЛОЦМАНа (Enter — взять, Delete — отменить);
--   Память — восстановленные записи, находки, заметки (Enter — читать); Стройка — планы прораба;
--   Устройства — что подключено и где Ящик памяти (Enter на инвентаре — сделать Ящиком памяти);
--   Настройки — ключ, адреса, модели… (Enter — изменить, ввод внизу; ключи — звёздочками; с ПИН — замок).
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

-- Встроенные вкладки; приложения (tmai.apps) встают между ними по order (M.set_apps).
local BASE_TABS = {
  { id = "home", title = "Главная", short = "Глав", order = 0 },
  { id = "chat", title = "Чат", short = "Чат", order = 10 },
  { id = "quests", title = "Задания", short = "Зад", order = 20 },
  { id = "memory", title = "Память", short = "Пам", order = 25 },
  { id = "build", title = "Стройка", short = "Стр", order = 85 },
  { id = "devices", title = "Устройства", short = "Устр", order = 90 },
  { id = "settings", title = "Настройки", short = "Наст", order = 95 },
}
local BASE_MON = { chat = true, quests = true, memory = true, build = true }
M.TABS = BASE_TABS
local MON_TABS = { "chat", "quests", "memory", "build" }
local MON_FOLLOW = false   -- ИИ показал план: монитор переключится на «Стройку»
M.apps = nil               -- реестр tmai.apps

local function app_of(id) return M.apps and M.apps.get(id) or nil end

-- Подключить приложения: вкладки терминала и монитора (monitor = true) по order.
function M.set_apps(reg)
  M.apps = reg
  local tabs = {}
  for _, tb in ipairs(BASE_TABS) do tabs[#tabs + 1] = tb end
  for _, a in ipairs(reg and reg.list or {}) do
    tabs[#tabs + 1] = { id = a.id, title = a.title, short = a.short, order = a.order, monitor = a.monitor }
  end
  table.sort(tabs, function(x, y)
    if x.order ~= y.order then return x.order < y.order end
    return x.id < y.id
  end)
  M.TABS = tabs
  MON_TABS = {}
  for _, tb in ipairs(tabs) do
    if BASE_MON[tb.id] or tb.monitor then MON_TABS[#MON_TABS + 1] = tb.id end
  end
end

-- Данные от app.lua: status, quests {active, available}, memory {rows}, devices {rows}, alerts, speaker, busy
M.data = { status = {}, quests = {}, memory = {}, devices = {}, alerts = {}, speaker = "Экипаж", busy = false }
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

-- Полоса вкладок (строка y от x, ширина w): полные имена, если влезают, иначе короткие; не влезают и они —
-- окно вокруг активной со стрелками < >. tabs = { {id, title, short}, … }. Возвращает зоны щелчка {x0, x1, id}.
local function draw_tabs(t, x, y, w, tabs, active)
  bar(t, x, y, w, colors.black)
  if #tabs == 0 then return {} end
  local function total(key)
    local n = 0
    for _, tb in ipairs(tabs) do n = n + text.len(tb[key]) + 1 end
    return n - 1
  end
  local key = total("title") <= w and "title" or "short"
  local first, last = 1, #tabs
  if total(key) > w then
    local ai = 1
    for i, tb in ipairs(tabs) do if tb.id == active then ai = i end end
    local room = w - 4
    first, last = ai, ai
    local used = text.len(tabs[ai][key])
    local grew = true
    while grew do
      grew = false
      if last < #tabs and used + 1 + text.len(tabs[last + 1][key]) <= room then
        last = last + 1; used = used + 1 + text.len(tabs[last][key]); grew = true
      end
      if first > 1 and used + 1 + text.len(tabs[first - 1][key]) <= room then
        first = first - 1; used = used + 1 + text.len(tabs[first][key]); grew = true
      end
    end
  end
  local zones = {}
  local xx = x
  if first > 1 then
    put(t, xx, y, "<", colors.gray, colors.black)
    zones[#zones + 1] = { x0 = xx, x1 = xx + 1, id = tabs[first - 1].id }
    xx = xx + 2
  end
  for i = first, last do
    local tb = tabs[i]
    local room = math.max(1, x + w - xx)
    local label = text.len(tb[key]) <= room and tb[key] or text.sub(tb[key], 1, room)
    local on = tb.id == active
    put(t, xx, y, label, on and colors.black or colors.lightGray, on and colors.cyan or colors.black)
    zones[#zones + 1] = { x0 = xx, x1 = xx + text.len(label) - 1, id = tb.id }
    xx = xx + text.len(label) + 1
  end
  if last < #tabs then
    put(t, x + w - 1, y, ">", colors.gray, colors.black)
    zones[#zones + 1] = { x0 = x + w - 2, x1 = x + w - 1, id = tabs[last + 1].id }
  end
  return zones
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
  local na = #(M.data.alerts or {})
  if na > 0 then table.insert(rows, 2, { "Тревоги", tostring(na), colors.red }) end
  return rows, p
end

-- ---------- терминал: состояние вкладок ----------
local T = { tab = "home", scroll = {}, sel = {}, edit = nil, read = nil, shift = false }
local ed, sed            -- строка чата и строка ввода (настройка, ввод приложения, ПИН)
-- T.edit: { setting = def } | { tab = id, p = prompt } | { pin = true }

local function term_size() return term.getSize() end

-- ПИН вкладки «Настройки» (tmai.pin): после верного ввода открыта 5 минут.
local function pin_value() return tostring(settings.get("tmai.pin") or "") end
local function settings_locked() return pin_value() ~= "" and os.clock() > (T.unlocked or -1) end
local function start_pin()
  local w, h = term_size()
  T.edit = { pin = true }
  sed = input.new({ term = term, x = 1, y = h, width = w, prompt = "ПИН: ", max = 8, history = false, mask = "*",
    placeholder = "ПИН настроек" })
end

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

-- Строка-состояние встроенной вкладки на «Главной».
local function builtin_status(id)
  if id == "chat" then return M.data.busy and "думает…" or nil end
  if id == "quests" then
    local a = (M.data.quests or {}).active
    return a and (tostring(a.title) .. " " .. tostring(a.progress or "")) or nil
  end
  if id == "build" and M.build and M.build.list_plans then
    local ok, plans = pcall(M.build.list_plans)
    return ok and plans and #plans > 0 and ("планов: " .. #plans) or nil
  end
  if id == "settings" and (settings.get("tmai.pin") or "") ~= "" then return "под ПИН" end
  return nil
end

local function home_rows()
  local out = {}
  local al = M.data.alerts or {}
  if #al > 0 then
    out[#out + 1] = { text = "Тревоги", header = true }
    for _, a in ipairs(al) do
      out[#out + 1] = { text = a.text, fg = a.level == "crit" and colors.red or (a.level == "info" and colors.lightGray or colors.orange),
        row = { kind = "alert" }, del = { kind = "alert_clear", key = a.key }, desc = "Delete — снять тревогу" }
    end
  end
  out[#out + 1] = { text = "Приложения", header = true }
  for _, tb in ipairs(M.TABS) do
    if tb.id ~= "home" then
      local a2 = app_of(tb.id)
      local st = a2 and M.apps.status(a2) or builtin_status(tb.id)
      out[#out + 1] = { text = tb.title, value = st, row = { kind = "open", id = tb.id }, desc = "Enter — открыть" }
    end
  end
  return out
end

-- Список строк вкладки-списка: { text=, value=, fg=, header=bool, row=…, action=…, del=…, prompt=…, desc= }
local function list_rows(tab, w)
  local out = {}
  local app = app_of(tab)
  if app then return M.apps.rows(app, w or (term_size())) end
  if tab == "home" then return home_rows() end
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
        if d.secret then   -- хвост показываем только у длинных ключей (короткий ПИН так выдал бы себя целиком)
          v = (v and v ~= "") and (#tostring(v) >= 12 and ("•••• " .. tostring(v):sub(-4)) or "задан") or "(не задан)"
        elseif type(v) == "boolean" then v = v and "да" or "нет"
        else v = tostring(v) end
        out[#out + 1] = { text = d.key, value = v, fg = colors.white, row = { kind = "setting", def = d } }
      end
    end
  end
  return out
end

local function selectable(rows, i)
  local r = rows[i]
  return r ~= nil and not r.header and (r.row ~= nil or r.action ~= nil or r.prompt ~= nil or r.del ~= nil)
end

local function fix_sel(tab, rows)
  local s = T.sel[tab] or 1
  if not selectable(rows, s) then
    for i = 1, #rows do if selectable(rows, i) then s = i; break end end
  end
  T.sel[tab] = s
  return s
end

local function move_sel(tab, dir)
  local rows = list_rows(tab, (term_size()))
  local s = fix_sel(tab, rows)
  local i = s + dir
  while rows[i] and not selectable(rows, i) do i = i + dir end
  if selectable(rows, i) then T.sel[tab] = i end
end

-- Нижняя строка-подсказка для вкладки.
local function hint_for(tab, sel_row)
  if T.read then return "Backspace/Enter — назад · PgUp/PgDn — листать" end
  if T.edit then return T.edit.pin and "Enter — открыть · ↑/↓ — назад" or "Enter — сохранить · ↑/↓ — отмена" end
  if sel_row and sel_row.hint then return sel_row.hint end
  if tab == "home" then return "↑↓ — выбор · Enter — открыть · печатайте — в чат" end
  local app = app_of(tab)
  if app then
    local hs = M.apps.hint(app, sel_row)
    if hs ~= "" then return hs end
    if sel_row and sel_row.prompt then return "Enter — " .. tostring(sel_row.prompt.label or "ввести") end
    local parts = {}
    if sel_row and sel_row.action then parts[#parts + 1] = "Enter — " .. tostring(sel_row.action.label or "выполнить") end
    if sel_row and sel_row.del then parts[#parts + 1] = "Delete — " .. tostring(sel_row.del.label or "удалить") end
    return #parts > 0 and table.concat(parts, " · ") or "↑↓ — выбор"
  end
  if tab == "chat" then return "Tab — вкладки · PgUp/PgDn — листать · «да КОД» — подтвердить" end
  if tab == "quests" then return "↑↓ — выбор · Enter — взять · Delete — отменить активное" end
  if tab == "memory" then return "↑↓ — выбор · Enter — читать" end
  if tab == "devices" then return sel_row and sel_row.action and "Enter — " .. sel_row.action.label or "↑↓ — выбор" end
  if tab == "settings" then return "↑↓ — выбор · Enter — изменить" end
  if tab == "build" then return "↑↓ — план · ←→ — слой · Enter — на монитор" end
  return ""
end

local function draw_list(t, x, y, w, h, tab)
  local rows = list_rows(tab, w)
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
    -- CC не принимает сам API term родителем окна («try term.current() instead»)
    local parent = (t == term) and term.current() or t
    b.render(window.create(parent, x, y, w, rows, true), id, layer, {})
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
  local na = #(M.data.alerts or {})
  if na > 0 then
    local al = " тревог: " .. na .. " "
    put(t, w - text.len(right) - text.len(al) + 1, 1, al, colors.white, colors.red)
  end
  -- строка 2: вкладки
  T.tab_x = draw_tabs(t, 1, 2, w, M.TABS, T.tab)
  -- содержимое: строки 3..h-2 (h-1 — подсказка/описание, h — ввод); чтение, стройка, свой вид — до h-1
  local cy, ch = 3, h - 4
  local sel_row
  local app = app_of(T.tab)
  if T.tab == "settings" and settings_locked() then
    if not (T.edit and T.edit.pin) then start_pin() end
    clear_area(t, 1, cy, w, ch + 1)
    put(t, 2, cy + 1, text.fit("Настройки закрыты ПИН-кодом.", w - 2), colors.yellow, colors.black)
    put(t, 2, cy + 2, text.fit("Введите ПИН внизу и Enter (↑ — назад).", w - 2), colors.lightGray, colors.black)
    if T.pin_msg then put(t, 2, cy + 4, text.fit(T.pin_msg, w - 2), colors.red, colors.black) end
  elseif T.read then
    draw_reader(t, 1, cy, w, ch + 1)
  elseif T.tab == "chat" then
    draw_feed(t, 1, cy, w, ch, T.scroll.chat or 0, M.data.busy)
  elseif T.tab == "build" then
    draw_build(t, 1, cy, w, ch + 1)
  elseif app and app.draw then
    clear_area(t, 1, cy, w, ch + 1)
    local okd, err = pcall(app.draw, app.ctx, t, 1, cy, w, ch + 1, "term")
    if not okd then put(t, 1, cy, text.fit("Ошибка: " .. tostring(err), w), colors.red, colors.black) end
  else
    sel_row = draw_list(t, 1, cy, w, ch, T.tab)
    -- под списком — описание выбранного
    local desc = ""
    if sel_row then
      if sel_row.row and sel_row.row.kind == "setting" then desc = sel_row.row.def.desc or ""
      elseif sel_row.row and sel_row.row.kind == "quest" then desc = sel_row.row.hint or ""
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
  T.edit = { setting = def }
  sed = input.new({ term = term, x = 1, y = h, width = w, prompt = def.key .. "= ", max = 300, history = false,
    mask = def.secret and "*" or nil,
    placeholder = def.key == "pin" and "4–8 цифр, пусто — без ПИН" or (def.secret and "вставьте ключ (Ctrl+V)" or "") })
  if not def.secret then sed:set(tostring(def.value == nil and "" or def.value)) end
  return nil
end

-- Строка ввода для приложения (prompt строки): введённое придёт в action как act.value.
local function start_prompt(tab, p)
  local w, h = term_size()
  T.edit = { tab = tab, p = p }
  sed = input.new({ term = term, x = 1, y = h, width = w, prompt = tostring(p.label or "Ввод") .. ": ",
    max = tonumber(p.max) or 200, history = false, mask = p.mask and "*" or nil, placeholder = p.placeholder or "" })
  if p.value ~= nil and p.value ~= "" then sed:set(tostring(p.value)) end
  return nil
end

-- Действие приложения: копия описания из строки + kind/app (ник говорящего добавит app.lua).
local function app_act(tab, a)
  local act = {}
  for k, v in pairs(a or {}) do act[k] = v end
  act.kind, act.app = "app", tab
  return act
end

local function activate(tab, rows)
  local r = rows[T.sel[tab] or 0]
  if not r then return nil end
  if r.prompt then return start_prompt(tab, r.prompt) end
  if tab == "home" and r.row and r.row.kind == "open" then M.show_tab(r.row.id); return nil end
  if r.action then return app_of(tab) and app_act(tab, r.action) or r.action end
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
  if T.tab == "settings" and settings_locked() and not (T.edit and T.edit.pin) then start_pin() end
  -- строка ввода: настройка, ввод приложения, ПИН
  if T.edit then
    if ev == "key" and (a == keys.up or a == keys.down or a == keys.tab) then
      if T.edit.pin then T.tab = "home" end
      T.edit = nil
      return acts
    end
    local r, txt = sed:handle(ev, a, b, c)
    local edited = r ~= nil
    if r == "submit" then
      local e = T.edit
      T.edit = nil
      if e.pin then
        if txt == pin_value() then T.unlocked, T.pin_msg = os.clock() + 300, nil
        else T.pin_msg = "неверный ПИН"; M.log_line("неверный ПИН настроек") end
      elseif e.setting then
        acts[#acts + 1] = { kind = "setting", key = e.setting.key, value = txt }
      else
        local act = app_act(e.tab, e.p)
        act.value, act.label, act.placeholder = txt, nil, nil
        acts[#acts + 1] = act
      end
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
  -- приложение со своим видом: ввод — ему
  local app = app_of(T.tab)
  if app and app.draw then
    if app.key then
      local okk, handled, act = pcall(app.key, app.ctx, ev, a, b, c)
      if okk and handled then
        if type(act) == "table" then acts[#acts + 1] = app_act(T.tab, act) end
        return acts, true
      end
    end
    return acts
  end
  -- на «Главной» начали печатать — это вопрос в чат
  if T.tab == "home" and (ev == "char" or ev == "paste") then T.tab = "chat" end
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
  local rows = list_rows(T.tab, w)
  fix_sel(T.tab, rows)
  if ev == "key" and a == keys.up then move_sel(T.tab, -1)
  elseif ev == "key" and a == keys.down then move_sel(T.tab, 1)
  elseif ev == "key" and a == keys.pageUp then for _ = 1, h - 6 do move_sel(T.tab, -1) end
  elseif ev == "key" and a == keys.pageDown then for _ = 1, h - 6 do move_sel(T.tab, 1) end
  elseif ev == "mouse_scroll" then move_sel(T.tab, a)
  elseif ev == "key" and a == keys.enter then
    local act = activate(T.tab, rows)
    if act then acts[#acts + 1] = act end
  elseif ev == "key" and a == keys.delete then
    local r = rows[T.sel[T.tab] or 0]
    if r and r.del then acts[#acts + 1] = app_of(T.tab) and app_act(T.tab, r.del) or r.del
    elseif T.tab == "quests" then acts[#acts + 1] = { kind = "quest_abandon" } end
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

function M.current_tab() return T.tab end

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
  local rows = list_rows(tab, w)
  local lines = {}
  for _, r in ipairs(rows) do
    local s = r.header and r.text or (((r.row or r.action) and "• " or "  ") .. r.text .. (r.value and ("  " .. tostring(r.value)) or ""))
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
  local mtabs = {}
  for _, id in ipairs(MON_TABS) do mtabs[#mtabs + 1] = M.TABS[tab_index(id)] end
  MON.tab_x = draw_tabs(mon, rx, 1, rw, mtabs, MON.tab)
  local mapp = app_of(MON.tab)
  if MON.tab == "chat" then
    draw_feed(mon, rx, 2, rw, h - 1, MON.scroll, M.data.busy)
  elseif MON.tab == "build" then
    draw_build(mon, rx, 2, rw, h - 1)
  elseif mapp and mapp.draw then
    MON.area = { x = rx, y = 2, w = rw, h = h - 1 }
    clear_area(mon, rx, 2, rw, h - 1)
    local okd, err = pcall(mapp.draw, mapp.ctx, mon, rx, 2, rw, h - 1, "monitor")
    if not okd then put(mon, rx, 2, text.fit("Ошибка: " .. tostring(err), rw), colors.red, colors.black) end
  else
    draw_mon_list(mon, rx, 2, rw, h - 1, MON.tab)
  end
  return true
end

-- Касание монитора: вкладки сверху, листание — верхняя/нижняя половина текста; у приложения со своим
-- видом и touch — касание ему. Возвращает действие приложения (или nil).
function M.handle_touch(side, x, y)
  if side ~= MON.name then return end
  if y == 1 then
    for _, tx in ipairs(MON.tab_x or {}) do
      if x >= tx.x0 and x <= tx.x1 then MON.tab = tx.id; MON.scroll = 0; return end
    end
    return
  end
  local tapp = app_of(MON.tab)
  local ar = MON.area
  if tapp and tapp.draw and tapp.touch and ar and x >= ar.x and x < ar.x + ar.w and y >= ar.y and y < ar.y + ar.h then
    local okt, act = pcall(tapp.touch, tapp.ctx, x - ar.x + 1, y - ar.y + 1, ar.w, ar.h)
    if okt and type(act) == "table" then return app_act(MON.tab, act) end
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
