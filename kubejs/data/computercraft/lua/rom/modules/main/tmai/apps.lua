-- tmai.apps — «приложения» ЛОЦМАНа: каждая вкладка-программа — модуль /rom/modules/main/tmai/apps/<id>.lua.
-- Реестр сам находит модули, даёт им общие службы (ctx), крутит их tick, очередь действий и запросов с КПК,
-- собирает их инструменты для нейросети. Встроенные вкладки (Главная, Чат, Задания, Память, Стройка,
-- Устройства, Настройки) живут в tmai.ui; приложения встают между ними по order.
--
-- Модуль приложения возвращает таблицу:
--   id = "base"                      -- латиница/цифры/_, совпадает с именем файла
--   title = "База", short = "База"   -- название вкладки; short (до 5 знаков) — когда места мало
--   order = 40                       -- место среди вкладок: Главная 0, Чат 10, Задания 20, Память 25,
--                                       приложения 30..80, Стройка 85, Устройства 90, Настройки 95
--   monitor = true                   -- показывать вкладкой и на мониторе (правая часть)
--   every = 5                        -- период tick, секунд (nil — без tick)
--
--   init(ctx)                        -- один раз при запуске. Не ждать (без периферии и сети)
--   tick(ctx)                        -- периодически, в корутине приложений: МОЖНО ждать периферию, ctx.nav(...)
--   action(ctx, act)                 -- действие со строки вкладки (Enter/Delete/ввод): act = { op=…, value=…
--                                       (текст из prompt), player=ник у терминала или nil, … поля из action }.
--                                       Выполняется в очереди приложений — МОЖНО ждать
--   radio = { <act> = function(ctx, msg, sender, player) -> data[, err] }
--                                    -- запросы с КПК: КПК шлёт по tmai_radio
--                                       { op="app", app=<id>, act=<act>, rid=…, player=<ник КПК>, …свои поля }
--                                       и получает { op="app_reply", app, act, rid, data=… | error=… }. МОЖНО ждать
--   tools(ctx, tctx) -> { defs }     -- инструменты для нейросети (формат как в tmai.tools); имена — с префиксом
--   run_tool(ctx, name, args, tctx)  -- "<id>_…". tctx.player — кто спросил. МОЖНО ждать. Вернуть таблицу/строку
--
--   НЕЛЬЗЯ ждать (вызываются при рисовании и в обработчике событий — только данные из ctx.data и кэша tick):
--   rows(ctx, w) -> rows             -- содержимое вкладки списком (вид как «Устройства»). Строка:
--        { text=, value= (справа), fg=colors.*, header=true (заголовок), desc= (подсказка снизу при выборе),
--          row={…} (строку можно выбрать), action={ op=…, … } (Enter), del={ op=…, … } (Delete),
--          prompt={ label="Имя метки", op="add", value="", mask=false, max=40, … } (Enter → строка ввода внизу,
--          введённое придёт в action как act.value) }
--   draw(ctx, t, x, y, w, h, where)  -- свой вид вместо rows; where = "term" | "monitor"
--   key(ctx, ev, a, b, c) -> handled[, act]  -- ввод для своего вида; act — действие в очередь (как со строки)
--   touch(ctx, x, y, w, h) -> act | nil  -- касание монитора в области вкладки (x, y — от 1 внутри неё)
--   hint(ctx, sel_row) -> строка     -- подсказка внизу вкладки (или строкой: hint = "…")
--   status(ctx) -> строка | nil      -- одна строка о себе на «Главной»
--   event(ctx, name, …)              -- любое событие компьютера (rednet_message, redstone, …); долгое — ctx.later
--
-- ctx — службы приложения:
--   ctx.id; ctx.data — сохраняемая таблица (/tmai/apps/<id>.json), ctx.save() — записать;
--   ctx.cfg() — настройки tmai; ctx.say(text, kind) — в ленту и на КПК (kind: ai|sys|warn);
--   ctx.alert — tmai.alert (тревоги: raise/clear с ключом "<id>.…"); ctx.nav(op, args, timeout) — операция TM-NAV
--   (свои операции — модулем /rom/modules/main/tmnav/<id>.lua); ctx.speaker() — ник у терминала или nil;
--   ctx.online() — ники онлайн; ctx.kpk(msg[, player]) — сообщение на КПК игрока (или на все);
--   ctx.later(fn, …) — выполнить в очереди приложений; ctx.redraw() — перерисовать экраны;
--   ctx.log(level, fmt, …); ctx.peripherals(type) — имена периферии этого типа; ctx.me — tmai.me;
--   ctx.text — tmai.text; ctx.util — tmai.util;
--   ctx.put(t, x, y, s, fg, bg) — печать строки (UTF-8 → шрифт CC; ВСЁ, что пишется на экран, — через неё
--   или text.cc), ctx.bar(t, x, y, w, bg) — закрасить полосу.

local util = require("tmai.util")
local text = require("tmai.text")

local M = {}

M.DIR = "/rom/modules/main/tmai/apps"
M.list, M.by_id = {}, {}

-- Префиксы встроенных инструментов: приложение не может так называться.
local RESERVED = { kb = true, memory = true, me = true, scout = true, quest = true, script = true, computers = true,
  build = true, power = true, comm = true, player = true, remember = true, forget = true, home = true, chat = true,
  quests = true, devices = true, settings = true }

local services = {}
local jobs = {}
local tool_owner = {}

local function app_dir() return util.DATA_DIR .. "/apps" end

local function make_ctx(app)
  local path = app_dir() .. "/" .. app.id .. ".json"
  local ctx = { id = app.id, text = text, util = util }
  ctx.data = util.load_json(path, {})
  if type(ctx.data) ~= "table" then ctx.data = {} end
  ctx.save = function()
    if not fs.exists(app_dir()) then fs.makeDir(app_dir()) end
    util.save_json(path, ctx.data)
  end
  ctx.cfg = function() return services.cfg and services.cfg() or {} end
  ctx.say = function(s, kind) if services.say then services.say(s, kind) end end
  ctx.alert = services.alert
  ctx.nav = function(op, args, timeout)
    if not services.nav then return nil, "нет связи с навигационным модулем" end
    return services.nav(op, args, timeout)
  end
  ctx.speaker = function() return services.speaker and services.speaker() or nil end
  ctx.online = function() return services.online and services.online() or {} end
  ctx.kpk = function(msg, player) if services.kpk then return services.kpk(msg, player) end end
  ctx.me = services.me
  ctx.later = function(fn, ...) M.enqueue(app, fn, ...) end
  ctx.redraw = function() os.queueEvent("tmai_ui", "app") end
  ctx.log = function(level, fmt, ...) util.log(level, "[" .. app.id .. "] " .. tostring(fmt), ...) end
  ctx.put = function(t, x, y, s, fg, bg)
    t.setCursorPos(x, y)
    if fg then t.setTextColor(fg) end
    if bg then t.setBackgroundColor(bg) end
    t.write(text.cc(s))
  end
  ctx.bar = function(t, x, y, w, bg)
    t.setCursorPos(x, y)
    if bg then t.setBackgroundColor(bg) end
    t.write((" "):rep(math.max(0, w)))
  end
  ctx.peripherals = function(ptype)
    local out = {}
    for _, n in ipairs(peripheral.getNames()) do if peripheral.hasType(n, ptype) then out[#out + 1] = n end end
    return out
  end
  return ctx
end

-- Загрузить приложения. svc — службы от app.lua: { cfg, say, alert, nav, speaker, online, kpk, me }.
function M.load(svc)
  services = svc or {}
  M.list, M.by_id, tool_owner = {}, {}, {}
  if not fs.isDir(M.DIR) then return M.list end
  local names = fs.list(M.DIR)
  table.sort(names)
  for _, f in ipairs(names) do
    local id = f:match("^([%w_]+)%.lua$")
    if id then
      local ok, app = pcall(require, "tmai.apps." .. id)
      if not ok or type(app) ~= "table" then
        util.log("E", "app %s: %s", id, tostring(app))
      elseif app.id ~= id or RESERVED[id] then
        util.log("E", "app %s: неверный id (%s)", id, tostring(app.id))
      else
        app.title = app.title or id
        app.short = app.short or text.sub(app.title, 1, 4)
        app.order = tonumber(app.order) or 50
        app.ctx = make_ctx(app)
        if app.init then
          local ok2, err = pcall(app.init, app.ctx)
          if not ok2 then app.broken = tostring(err); util.log("E", "app %s init: %s", id, app.broken) end
        end
        M.list[#M.list + 1] = app
        M.by_id[id] = app
      end
    end
  end
  table.sort(M.list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
  end)
  return M.list
end

function M.get(id) return M.by_id[id] end

-- ---------- очередь (действия, запросы КПК, ctx.later) ----------
function M.enqueue(app, fn, ...)
  jobs[#jobs + 1] = { app = app, fn = fn, args = table.pack(...) }
  os.queueEvent("tmai_apps")
end

-- Действие экрана: { kind="app", app=id, op=…, … }
function M.action(act)
  local app = M.by_id[act.app]
  if not app or not app.action or app.broken then return false end
  M.enqueue(app, app.action, app.ctx, act)
  return true
end

-- Запрос с КПК (из обработчика событий: только ставит в очередь). reply(t) — ответ этому КПК.
function M.radio(sender, msg, player, reply)
  local app = M.by_id[msg.app]
  local h = app and not app.broken and app.radio and app.radio[msg.act]
  local base = { op = "app_reply", app = msg.app, act = msg.act, rid = msg.rid }
  if not h then
    base.error = app and "нет такой операции" or "нет такого приложения"
    reply(base)
    return
  end
  M.enqueue(app, function()
    local ok, data, err = pcall(h, app.ctx, msg, sender, player)
    if ok and data ~= nil then base.data = data
    else base.error = ok and tostring(err or "нет данных") or tostring(data) end
    reply(base)
  end)
end

-- Выполнить всё, что накопилось в очереди (корутина приложений; в тестах — напрямую).
function M.run_pending()
  while #jobs > 0 do
    local j = table.remove(jobs, 1)
    local ok, err = pcall(j.fn, table.unpack(j.args, 1, j.args.n))
    if not ok then util.log("E", "app %s: %s", j.app.id, tostring(err)) end
    os.queueEvent("tmai_ui", "app")
  end
end

local function run_jobs()
  while true do
    M.run_pending()
    os.pullEvent("tmai_apps")
  end
end

local function run_ticks()
  local next_t = {}
  while true do
    local wait = 10
    for _, app in ipairs(M.list) do
      if app.tick and app.every and not app.broken then
        if os.clock() >= (next_t[app.id] or 0) then
          local ok, err = pcall(app.tick, app.ctx)
          if not ok then util.log("W", "app %s tick: %s", app.id, tostring(err)) end
          next_t[app.id] = os.clock() + math.max(0.5, tonumber(app.every) or 5)
          os.queueEvent("tmai_ui", "app")
        end
        wait = math.min(wait, math.max(0.05, next_t[app.id] - os.clock()))
      end
    end
    sleep(wait)
  end
end

-- Корутина приложений (запускает app.lua в parallel): tick по расписанию и очередь — отдельно,
-- чтобы долгий tick одного приложения не задерживал нажатия в другом.
function M.loop()
  parallel.waitForAll(run_jobs, run_ticks)
end

-- ---------- события (нельзя ждать) ----------
function M.event(name, ...)
  for _, app in ipairs(M.list) do
    if app.event and not app.broken then
      local ok, err = pcall(app.event, app.ctx, name, ...)
      if not ok then util.log("W", "app %s event: %s", app.id, tostring(err)) end
    end
  end
end

-- ---------- нейросеть ----------
function M.tool_defs(tctx)
  local out = {}
  for _, app in ipairs(M.list) do
    if app.tools and not app.broken then
      local ok, defs = pcall(app.tools, app.ctx, tctx)
      if ok and type(defs) == "table" then
        for _, d in ipairs(defs) do
          if type(d.name) == "string" and d.name:sub(1, #app.id + 1) == app.id .. "_" then
            out[#out + 1] = d
            tool_owner[d.name] = app
          end
        end
      elseif not ok then
        util.log("W", "app %s tools: %s", app.id, tostring(defs))
      end
    end
  end
  return out
end

function M.owns(name)
  if type(name) ~= "string" then return nil end
  if tool_owner[name] then return tool_owner[name] end
  for _, app in ipairs(M.list) do
    if name:sub(1, #app.id + 1) == app.id .. "_" then return app end
  end
  return nil
end

function M.run_tool(name, args, tctx)
  local app = M.owns(name)
  if not app or not app.run_tool or app.broken then return "нет такого инструмента" end
  local ok, r = pcall(app.run_tool, app.ctx, name, args or {}, tctx or {})
  if not ok then
    util.log("W", "app %s tool %s: %s", app.id, name, tostring(r))
    return "ошибка: " .. tostring(r)
  end
  if r == nil then return "готово" end
  return r
end

-- ---------- для экранов (нельзя ждать) ----------
function M.rows(app, w)
  if app.broken then return { { text = "Приложение не запустилось: " .. app.broken, fg = colors.red } } end
  if not app.rows then return {} end
  local ok, rows = pcall(app.rows, app.ctx, w)
  if not ok then return { { text = "Ошибка: " .. tostring(rows), fg = colors.red } } end
  return type(rows) == "table" and rows or {}
end

function M.status(app)
  if app.broken then return "не запустилось" end
  if not app.status then return nil end
  local ok, s = pcall(app.status, app.ctx)
  return ok and s and tostring(s) or nil
end

function M.hint(app, sel_row)
  if type(app.hint) == "function" then
    local ok, s = pcall(app.hint, app.ctx, sel_row)
    return ok and s and tostring(s) or ""
  end
  return app.hint or ""
end

return M
