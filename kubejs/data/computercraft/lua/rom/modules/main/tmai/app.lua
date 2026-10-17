-- tmai.app — главный цикл ЛОЦМАНа (компьютер капсулы, метка TM-AI).
-- С ЛОЦМАНом говорят только через терминал этого компьютера (вкладка «Чат») и через КПК (rednet) —
-- игровой чат не используется. Корутины (parallel):
--   listener — все события: терминал и монитор (tmai.ui), rednet (КПК, вышки, агенты программ), модемы, МЭ;
--   worker   — очередь: вопросы к нейросети, команды «да КОД»/«стоп», поручения, находки, исправление программ;
--   poller   — Ящик памяти (находки, ключи слоёв, детали ремонта), поручения, статус штурманского модуля;
--   watcher  — кто стоит у терминала (детектор игроков), кто онлайн;
--   ambience — напевание ночью, утренние строки после финала;
--   ui       — данные для экранов и перерисовка терминала/монитора;  embedder — векторы базы знаний;
--   apps     — приложения (tmai.apps: вкладки-программы, их tick, очередь действий и запросов КПК).
-- Всё, что модель может «сделать», проходит через tools.lua (белый список) и штурманский модуль TM-NAV.

local config = require("tmai.config")
local util = require("tmai.util")
local u8 = require("tmai.u8")
local power = require("tmai.power")
local kb = require("tmai.kb")
local embed = require("tmai.embed")
local lore = require("tmai.lore")
local me = require("tmai.me")
local link = require("tmai.link")
local quests = require("tmai.quests")
local history = require("tmai.history")
local scripts = require("tmai.scripts")
local tools = require("tmai.tools")
local prompt = require("tmai.prompt")
local llm = require("tmai.llm")
local guard = require("tmai.guard")
local tts = require("tmai.tts")
local ui = require("tmai.ui")
local feed = require("tmai.feed")
local who = require("tmai.who")
local extras = require("tmai.extras")
local apps = require("tmai.apps")
local alert = require("tmai.alert")
local PULL_EVENT = os.pullEvent       -- с ПИН-кодом Ctrl+T не останавливает программу (os.pullEventRaw)
local okb, build = pcall(require, "tmai.build")
if not okb then build = nil end

local App = {}

local cfg, state
local queue = {}
local working = false          -- worker занят заданием (для «ЛОЦМАН думает…»)
local nav = nil                -- статус TM-NAV: { x,y,z,dim, repair, radio, radios }
local nav_fail = 0             -- сколько опросов подряд модуль не ответил
local nav_where = nil          -- где модуль и радио (для записи в лог при переезде)
local llm_status = "?"
local last_talk_t = 0          -- когда в последний раз говорили (для напевания)
local STATE_PATH = util.DATA_DIR .. "/state.json"

local function save_state() util.save_json(STATE_PATH, state) end

local function push(job)
  queue[#queue + 1] = job
  os.queueEvent("tmai_queue")
  os.queueEvent("tmai_ui", "queue")
end

-- ---------- имя и голос по режиму ----------
local function persona_name()
  local ep = lore.epilogue()
  if ep == "b" then return "ШТУРМАН-4" end
  if ep == "c" then return "МАРА" end
  return "ЛОЦМАН"
end

-- КПК на связи: кому слать объявления
local function pdas_recent()
  local out = {}
  for id, p in pairs(state.pdas or {}) do
    if util.now() - (p.t or 0) < 1800 then out[#out + 1] = tonumber(id) end
  end
  return out
end

-- Сказать вслух экипажу: лента (терминал, монитор) + объявление на КПК в зоне радио.
local function say(text, kind)
  last_talk_t = util.now()
  feed.add(kind or "ai", kind == "sys" and "Капсула" or persona_name(), text)
  if #pdas_recent() > 0 then
    pcall(rednet.broadcast, { op = "notify", text = text, from = persona_name() }, link.RADIO)
  end
end

-- Тревога (tmai.alert): лента, все КПК в зоне радио (с уровнем) и сигнал колонки.
local function alarm(text, level)
  last_talk_t = util.now()
  feed.add(level == "info" and "sys" or "warn", "Тревога", text)
  if #pdas_recent() > 0 then
    pcall(rednet.broadcast, { op = "notify", text = text, level = level, from = "Тревога" }, link.RADIO)
  end
  if level ~= "info" then
    local sp = peripheral.find("speaker")
    if sp then pcall(sp.playNote, "bell", 1, level == "crit" and 18 or 12) end
  end
end

-- Сообщение приложения на КПК игрока (по нику, с которым КПК выходил на связь) или на все.
local function kpk_send(msg, player)
  if player == nil then return pcall(rednet.broadcast, msg, link.RADIO) end
  local sent = false
  local want = tostring(player):lower()          -- ник на КПК могли набрать в другом регистре
  for id, p in pairs(state.pdas or {}) do
    if tostring(p.player or ""):lower() == want then pcall(rednet.send, tonumber(id), msg, link.RADIO); sent = true end
  end
  return sent
end

-- ---------- периферия ----------
local function core_name()
  local core = peripheral.find("kubejs:ai_core")
  return core and peripheral.getName(core) or nil
end

-- Ящик памяти: выбранный во вкладке «Устройства» (tmai.memory_box); иначе инвентарь вплотную к компьютеру
-- (не ядро); иначе первый в проводной сети. После переезда в сети могут оказаться чужие сундуки базы.
local SIDE = {}
for _, s in ipairs(redstone.getSides()) do SIDE[s] = true end

local function inventories()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "inventory") and not peripheral.hasType(name, "kubejs:ai_core") then out[#out + 1] = name end
  end
  return out
end

local function memory_box()
  local want = cfg and cfg.memory_box or ""
  if want ~= "" and peripheral.hasType(want, "inventory") then return peripheral.wrap(want), want end
  local remote
  for _, name in ipairs(inventories()) do
    if SIDE[name] then return peripheral.wrap(name), name end
    remote = remote or name
  end
  if remote then return peripheral.wrap(remote), remote end
end

local function open_rednet()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then pcall(rednet.open, name) end
  end
end

-- ---------- ответы ----------
local function reply(job, text)
  if job.via == "radio" and job.reply_to then
    rednet.send(job.reply_to, { op = "answer", text = text, player = job.player, from = persona_name() }, link.RADIO)
  end
  last_talk_t = util.now()
  feed.add("ai", persona_name(), text)
end

-- Фраза-триггер «Сценариев» (tmai/apps/auto.lua): ловится сразу при вводе — до очереди, нейросети и её лимитов.
-- true — сценарий сработал, ответ уже в ленте/на КПК.
local function auto_phrase(player, text, via, reply_to)
  local auto = apps.get("auto")
  if not (auto and not auto.broken and auto.on_phrase) then return false end
  if not (cfg.allowed["*"] or cfg.allowed[player]) then return false end
  local ok, handled, answer = pcall(auto.on_phrase, auto.ctx, text, player, via)
  if not ok then util.log("W", "auto.on_phrase: %s", tostring(handled)); return false end
  if not handled then return false end
  reply({ via = via, reply_to = reply_to, player = player }, answer or "Готово.")
  return true
end

local function status_text(p)
  local parts = { power.describe(p) }
  if nav then
    parts[#parts + 1] = string.format("ремонт ядра (штурманский модуль): ступень %d из 4", nav.repair or 0)
    parts[#parts + 1] = guard.describe(nav)
  else
    parts[#parts + 1] = "штурманский модуль: нет связи"
  end
  local ms = me.status()
  parts[#parts + 1] = ms.connected and "МЭ-сеть подключена (инструменты me_*)" or "МЭ-сеть не подключена (нужен ME-мост у терминала)"
  local q = quests.active()
  if q then parts[#parts + 1] = "активное поручение: " .. q.title .. " (" .. tostring(q.progress or "") .. ")" end
  if build and build.status_lines then
    local bl = build.status_lines()
    if bl and bl[1] then parts[#parts + 1] = "стройка: " .. table.concat(bl, "; ") end
  end
  parts[#parts + 1] = "время в мире: " .. textutils.formatTime(os.time(), true) .. ", день " .. os.day()
  return table.concat(parts, "\n")
end

local function players_text(asker, via)
  local names = who.online()
  return (#names > 0 and table.concat(names, ", ") or "(неизвестно)") ..
    "\nСейчас спрашивает: " .. tostring(asker) .. (via == "radio" and " (с КПК, издалека)" or " (у терминала капсулы)")
end

local function ctx_for(player)
  return {
    player = player, cfg = cfg, lore_level = lore.level(), repair = nav and nav.repair or 0,
    has_me = me.attach(), has_nav = nav ~= nil, has_exec = #scripts.list_targets() > 0,
    has_build = build ~= nil,
  }
end

-- Стабильная часть промпта: личность, характер по слоям, память, сводка, заметки.
local function build_system()
  local memory = lore.memory_digest(cfg.memory_chars)
  return prompt.build({
    NAME = persona_name(),
    STYLE = lore.style(),
    MEMORY = memory ~= "" and memory or "(пусто)",
    SUMMARY = history.summary() ~= "" and history.summary() or "(нет)",
    NOTES = history.notes_text() ~= "" and history.notes_text() or "(нет)",
    TOOLS = llm.tools_supported == false and
      "\nВНИМАНИЕ: сервер модели не поддерживает инструменты — склад, разведка, поручения и программы сейчас недоступны; говори об этом прямо." or "",
  })
end

-- Контекст хода (меняется каждый раз) — после истории, чтобы начало запроса оставалось стабильным.
local function build_context(question, player, p, via)
  local kbtext = kb.context_for(question, lore.level(), cfg.kb_chars)
  return "СОСТОЯНИЕ\n" .. status_text(p) ..
    "\n\nИГРОКИ ОНЛАЙН\n" .. players_text(player, via) ..
    "\n\nСПРАВКА (подобрана по вопросу)\n" .. (kbtext ~= "" and kbtext or "(по этому вопросу в справочнике ничего не найдено)")
end

local function new_conv_id()
  state.conv_id = ("tm-%d-%d"):format(os.getComputerID(), os.epoch("utc"))
  save_state()
end

-- Ошибки связи — «в образе».
local function error_phrase(code)
  if code == 401 or code == 403 then return "[ошибка авторизации логического ядра] Проверьте ключ: терминал капсулы → Настройки → api_key." end
  if code == 429 then return "[канал перегружен] Слишком много запросов — повторите через минуту." end
  if code == 502 or code == 503 or code == 504 or code == nil then return "[помехи] Нет связи с логическим ядром. Повторите позже." end
  if code == 404 then return "[сбой] Логическое ядро не отвечает на этот адрес — проверьте model и base_url в Настройках." end
  return "[сбой обработки запроса] Попробуйте сформулировать иначе."
end

local function compact_history()
  if not history.needs_compaction() then return end
  local done = history.compact(function(old, prev)
    return llm.simple(cfg,
      "Ты сжимаешь журнал разговора экипажа с бортовым ассистентом. Пиши по-русски, сухо, до " ..
      math.floor(settings.get("tmai.summary_chars", 8000) / 2) .. " символов: " ..
      "кто что спрашивал, договорённости, найденные места и координаты, незавершённые дела. Без воды.",
      "Предыдущая сводка:\n" .. (prev ~= "" and prev or "(нет)") .. "\n\nНовый фрагмент журнала:\n" .. old)
  end)
  if done then new_conv_id() end -- история переписана: шлюз должен начать новую сессию
end

-- ---------- задания очереди ----------
local function handle_ask(job)
  local p = power.status()
  if not p.ok then
    reply(job, "[аварийный режим] " .. (p.hint or "Питание ядра ниже минимума. Загрузите топливо в генератор в полу перед терминалом."))
    return
  end
  local ready, why = config.check(cfg)
  if not ready then
    reply(job, "[нет связи с логическим ядром] Требуется настройка: терминал капсулы → вкладка «Настройки».")
    ui.log_line(why)
    return
  end
  if job.text == "" then
    reply(job, "Слушаю, " .. job.player .. ".")
    return
  end
  power.thinking(true)
  local ctx = ctx_for(job.player)
  ctx.text = job.text
  if not state.conv_id then new_conv_id() end
  local answer, err, code = llm.ask({
    cfg = cfg, system = build_system(), history = history.messages(),
    user = job.text, user_name = job.player, context = build_context(job.text, job.player, p, job.via),
    conv_id = state.conv_id, tools = tools.available(ctx),
    run_tool = function(name, args) return tools.run(name, args, ctx) end,
  })
  power.thinking(false)
  if not answer then
    llm_status = "error"
    util.log("E", "llm: %s", tostring(err))
    ui.log_line("нейросеть: " .. tostring(err):sub(1, 60))
    reply(job, error_phrase(code))
    return
  end
  llm_status = "ok"
  history.add("user", job.player, job.text)
  history.add("assistant", nil, answer)
  reply(job, answer)
  tts.speak(answer, job.via == "radio" and job.reply_to or nil)
  save_state()
end

-- Реакция нейросети на событие памяти (необязательная: без связи — только каноничный текст).
local function react(instruction)
  if not config.check(cfg) or not power.status().ok then return nil end
  power.thinking(true)
  local answer = llm.simple(cfg, build_system(), "[система капсулы, не игрок]: " .. instruction)
  power.thinking(false)
  return answer
end

local function handle_memory(job)
  local events = lore.on_item(job.item, job.player)
  if #events == 0 then return end
  save_state()
  for _, ev in ipairs(events) do
    if ev.kind == "layer" then
      new_conv_id()   -- системный промпт изменился: новая сессия шлюза
      say("Печать сектора " .. ev.n .. " снята. Восстановленная запись: «" .. ev.title .. "».")
      say(ev.record)
      history.add("assistant", nil, ev.record)
      if cfg.print_records then extras.print_record(ev.n, ev.title, ev.record) end
      extras.chime()
    elseif ev.kind == "pending" then
      say("Носитель принят. Сектор опечатан глубже, чем я могу заглянуть сейчас. Сохраню до лучших времён.")
    elseif ev.kind == "epilogue" then
      new_conv_id()
      local lines = { a = "…Значит, будем учить их сами. С азбуки. Это дольше. Зато это будет их.",
                      b = "ШТУРМАН-4. Справочник к вашим услугам.",
                      c = "Привет. Это я. Мы. …Я." }
      say(lines[ev.code] or "…")
    elseif ev.kind == "note" then
      if not ev.understood then
        say("Носитель «" .. ev.title .. "» принят. Фрагмент без контекста: нужный сектор памяти ещё опечатан. Сохраню.")
      else
        say("Носитель «" .. ev.title .. "» принят. Читаю…")
        local answer = react("Экипаж только что положил в Ящик памяти находку «" .. ev.title .. "» (она уже у тебя, просить положить её не нужно). Её текст:\n" .. ev.text ..
          "\n\nОтреагируй вслух для экипажа в 2–4 предложениях: что ты понял и что тебя зацепило. Не пересказывай дословно, " ..
          "не делай выводов сверх восстановленной памяти, не раскрывай того, чего в ней нет.")
        if answer then
          history.add("assistant", nil, answer)
          say(answer)
          tts.speak(answer)
        end
      end
    end
  end
end

local function handle_fix(job)
  local ctx = ctx_for(job.player)
  ctx.text = job.text
  local answer = llm.ask({
    cfg = cfg, system = build_system(), context = build_context("скрипт lua cc tweaked ошибка", job.player, power.status(), "pc"),
    history = {}, user = job.text, user_name = job.player, tools = tools.available(ctx),
    run_tool = function(name, args) return tools.run(name, args, ctx) end,
  })
  if answer and answer ~= "" then say(answer) end
end

local function handle_relay_setup(job)
  local r, err = link.call("relay_probe", { player = job.player, relay = job.sender }, 10)
  if r then
    guard.relay_register(job.sender, r)
    save_state()
    rednet.send(job.sender, { op = "relay_ok", info = r }, "tmai_relay_setup")
    say(("Вышка #%d на связи: %s"):format(job.sender, r.ender and "эндер-модем, без ограничений" or ("дальность " .. r.range .. " блоков")))
  else
    rednet.send(job.sender, { op = "relay_fail", error = tostring(err) }, "tmai_relay_setup")
  end
end

-- Детерминированные команды (без нейросети): «да КОД [авто]», «стоп [КОД]». true — команда выполнена.
local function direct_command(job)
  local low = u8.lower(u8.trim(job.text))
  local code, auto = low:match("^да%s+(%d%d%d)%s*(%S*)")
  local out
  if code then
    if scripts.is_job(code) then
      local j = scripts.confirm(code, auto == "авто")
      out = j and ("Запускаю " .. j.name .. " на компьютере #" .. j.target .. ".") or "Нет такой программы."
    elseif build and build.is_job and build.is_job(code) then
      local r, err = build.confirm(code, job.player)
      out = r and (type(r) == "string" and r or "Стройка запущена.") or ("Не выполнено: " .. tostring(err))
    else
      local r, err = me.confirm(code, job.player)
      out = r and ("Заказ принят: " .. r.item .. " x" .. r.count .. ".") or ("Не выполнено: " .. tostring(err))
    end
  else
    local stop = low:match("^стоп%s*(%d*)$")
    if not stop then return false end
    local n = scripts.stop(stop ~= "" and stop or nil)
    local auto = apps.get("auto")
    if stop == "" and auto and auto.stop_runs then pcall(auto.stop_runs, auto.ctx) end   -- сценарии, ждущие на wait
    local nb = 0
    if build and build.stop and stop == "" then local okb2, r = pcall(build.stop); nb = okb2 and tonumber(r) or 0 end
    out = "Остановлено программ: " .. n .. (nb > 0 and (", строек: " .. nb) or "")
  end
  reply(job, out)
  return true
end

local function handle_input(job)
  if direct_command(job) then return end
  local ok, why = guard.allow(cfg, job.player, job.text, 0)
  if not ok then
    if why ~= "слишком часто" then reply(job, "[" .. why .. "]") else feed.add("sys", "Капсула", "Не так быстро: подождите пару секунд.") end
    return
  end
  handle_ask(job)
end

local function worker()
  while true do
    if #queue == 0 then os.pullEvent("tmai_queue") end
    local job = table.remove(queue, 1)
    if job then
      working = true
      os.queueEvent("tmai_ui", "busy")
      local ok, err = pcall(function()
        if job.kind == "input" then handle_input(job)
        elseif job.kind == "memory" then handle_memory(job)
        elseif job.kind == "fix" then handle_fix(job)
        elseif job.kind == "relay_setup" then handle_relay_setup(job)
        elseif job.kind == "quest_accept" then
          local r, e = quests.accept(job.id, job.player, nav and nav.repair or 0)
          say(r and ("Поручение «" .. tostring(r.title) .. "» за " .. tostring(r.player) .. ".") or ("Не взять: " .. tostring(e)), r and "ai" or "warn")
          save_state()
        elseif job.kind == "quest_abandon" then
          quests.abandon(); save_state(); say("Поручение отменено.", "sys")
        end
      end)
      power.thinking(false)
      working = false
      os.queueEvent("tmai_ui", "idle")
      if not ok then util.log("E", "job %s failed: %s", tostring(job.kind), tostring(err)) end
      pcall(compact_history)
    end
  end
end

-- ---------- действия экранов ----------
local function apply_config()
  cfg = config.get()
  util.set_debug(cfg.debug)
  power.configure(cfg); embed.configure(cfg); tts.configure(cfg)
  os.pullEvent = (cfg.pin or "") ~= "" and os.pullEventRaw or PULL_EVENT
  os.queueEvent("tmai_embed")          -- ключ/адрес/модель могли смениться — пересобрать поиск по смыслу
end

local function ui_action(act)
  if act.kind == "say" then
    local player = ui.data.speaker or "Экипаж"
    if who.valid(player) then state.last_speaker = player end
    who.manual = nil
    local text = u8.truncate(act.text, cfg.max_input * 2)
    feed.add("user", player, text)
    if auto_phrase(player, text, "pc") then return end
    if #queue >= cfg.queue_limit then feed.add("warn", "Капсула", "Очередь занята — подождите ответа."); return end
    push({ kind = "input", player = player, text = text, via = "pc" })
  elseif act.kind == "cycle_speaker" then
    who.manual = who.cycle(ui.data.speaker)
    ui.data.speaker = who.manual
  elseif act.kind == "setting" then
    local ok, err = config.set(act.key, act.value)
    if ok then
      apply_config()
      ui.log_line("сохранено: " .. act.key)
      if act.key == "api_key" or act.key == "base_url" or act.key == "model" then llm_status = "?" end
    else
      ui.log_line(act.key .. ": " .. tostring(err))
      feed.add("warn", "Капсула", "Настройка " .. act.key .. " не сохранена: " .. tostring(err))
    end
  elseif act.kind == "memory_box" then
    config.set("memory_box", act.name); apply_config()
    feed.add("sys", "Капсула", "Ящик памяти теперь: " .. act.name)
  elseif act.kind == "quest_accept" then
    push({ kind = "quest_accept", id = act.id, player = ui.data.speaker or "Экипаж" })
  elseif act.kind == "quest_abandon" then
    push({ kind = "quest_abandon" })
  elseif act.kind == "build_show" and build and build.select then
    build.select(act.id, act.layer)     -- шлёт tmai_ui build → монитор переключится на «Стройку»
  elseif act.kind == "app" then
    local sp = ui.data.speaker
    act.player = who.valid(sp) and sp or nil
    apps.action(act)
  elseif act.kind == "alert_clear" then
    alert.clear(act.key)
  end
end

local function on_radio(sender, msg)
  local player = tostring(msg.player or ("КПК#" .. sender))
  if not player:match("^[%w_]+$") then player = "КПК" .. sender end
  state.pdas = state.pdas or {}
  state.pdas[tostring(sender)] = { player = player, t = util.now() }
  if msg.op == "ping" then
    rednet.send(sender, { op = "pong", from = persona_name() }, link.RADIO)
    return
  end
  local text = u8.truncate(msg.text, cfg.max_input * 2)
  feed.add("user", player .. " (КПК)", text)
  if auto_phrase(player, text, "radio", sender) then return end
  if #queue >= cfg.queue_limit then
    rednet.send(sender, { op = "answer", text = "[очередь занята]" }, link.RADIO); return
  end
  push({ kind = "input", player = player, text = text, via = "radio", reply_to = sender })
end

local TERM_EVENTS = { key = true, key_up = true, char = true, paste = true, mouse_click = true, mouse_scroll = true,
  mouse_drag = true, mouse_up = true, timer = true, term_resize = true }

local function listener()
  while true do
    local ev = { os.pullEvent() }
    local name = ev[1]
    if TERM_EVENTS[name] then
      local okh, acts, dirty = pcall(ui.handle_term, name, ev[2], ev[3], ev[4])
      if not okh then util.log("E", "ui: %s", tostring(acts)); acts, dirty = {}, true end
      for _, a in ipairs(acts or {}) do
        local ok, err = pcall(ui_action, a)
        if not ok then util.log("E", "ui action %s: %s", tostring(a.kind), tostring(err)) end
      end
      if dirty then pcall(ui.draw_term) end
    elseif name == "tmai_ui" and ev[2] == "build" then
      ui.follow_build(ev[3], ev[4])
    elseif name == "monitor_touch" then
      local okt, tact = pcall(ui.handle_touch, ev[2], ev[3], ev[4])
      if okt and tact then pcall(ui_action, tact) end
      os.queueEvent("tmai_ui", "touch")
    elseif name == "modem_message" then
      link.on_modem_message(ev[2], ev[3], ev[4], ev[5], ev[6])
    elseif name == "rednet_message" then
      local sender, msg, proto = ev[2], ev[3], ev[4]
      if proto == link.RADIO and type(msg) == "table" and ((msg.op == "ask" and type(msg.text) == "string") or msg.op == "ping") then
        on_radio(sender, msg)
      elseif proto == link.RADIO and type(msg) == "table" and msg.op == "app" and type(msg.app) == "string" and type(msg.act) == "string" then
        local player = tostring(msg.player or "")
        if not who.valid(player) then player = nil end
        state.pdas = state.pdas or {}
        state.pdas[tostring(sender)] = { player = player or ("КПК" .. sender), t = util.now() }
        apps.radio(sender, msg, player, function(t) rednet.send(sender, t, link.RADIO) end)
      elseif proto == "tmai_relay" and type(msg) == "table" and msg.op == "relay_hb" then
        guard.relay_beacon(sender)
      elseif proto == "tmai_relay_setup" and type(msg) == "table" and msg.op == "setup" and type(msg.player) == "string" then
        push({ kind = "relay_setup", sender = sender, player = msg.player })
      elseif proto == scripts.PROTO then
        local j, m = scripts.on_rednet(sender, msg)
        if j and m.state == "error" then
          -- о падении сообщает тревога приложения «Программы»; без него — строкой в ленту
          if not apps.get("programs") then say("Программа " .. j.name .. " упала: " .. tostring(m.error):sub(1, 200), "warn") end
          if j.auto and (j.fixes or 0) < 3 then push({ kind = "fix", player = j.player, text = scripts.fix_prompt(j) }) end
        elseif j and m.state == "done" then
          say("Программа " .. j.name .. " завершена.", "sys")
        end
      elseif build and build.PROTO and proto == build.PROTO then
        local okr, note = pcall(build.on_rednet, sender, msg)
        if okr and note then say(note, "sys") end
        os.queueEvent("tmai_ui", "build")
      end
    elseif name == "ae_crafting" then
      local text = me.on_event(ev[2], ev[3], ev[4])
      if text then say(text, "sys") end
    elseif name == "peripheral" or name == "peripheral_detach" then
      power.attach(); me.attach(); link.attach(); open_rednet(); extras.attach(); who.attach(); ui.reset_monitor()
      os.queueEvent("tmai_ui", "peripheral")
    end
    if not TERM_EVENTS[name] and name ~= "tmai_ui" and name ~= "tmai_apps" then apps.event(name, table.unpack(ev, 2)) end
  end
end

-- ---------- периодические проверки ----------
local REPAIR_PARTS = {}
for _, r in ipairs(util.read_tsv(util.ROM_DIR .. "/repair.tsv")) do REPAIR_PARTS[r.item] = true end

-- Настройка proxy действует на весь мир: её включает штурманский модуль командой /tmproxy.
-- Шлём, когда значение изменилось; не вышло — повторяем на следующих кругах, о сбое пишем один раз.
local function sync_proxy()
  local want = cfg.proxy or ""
  if want == (state.proxy_sent or "") then return end
  local r, err = link.call("proxy", { url = want }, 5)
  if r then
    state.proxy_sent, state.proxy_warned = want, nil
    feed.add("sys", "Капсула", want == "" and "Прокси выключен: в интернет — напрямую."
      or ("Прокси включён: " .. config.proxy_label(want) .. ". Домашняя сеть — напрямую."))
    save_state()
    os.queueEvent("tmai_embed")        -- поиск по смыслу мог не собраться без прокси
  elseif state.proxy_warned ~= want then
    state.proxy_warned = want
    feed.add("warn", "Капсула", "Прокси пока не включён: " .. tostring(err) .. ". Повторю сам.")
    save_state()
  end
end

local function poller()
  local tick = 0
  while true do
    tick = tick + 1
    local box = memory_box()
    if box then
      local ok, items = pcall(box.list)
      if ok and items then
        for slot, it in pairs(items) do
          if lore.is_interesting(it.name) then
            if not state.seen_items[it.name] then
              state.seen_items[it.name] = true
              push({ kind = "memory", item = it.name, player = "экипаж" })
            end
          elseif REPAIR_PARTS[it.name] then
            local cn = core_name()
            if cn then pcall(box.pushItems, cn, slot, 1) end
          end
        end
      end
    end
    if tick % 3 == 1 then
      local s, err = link.call("status", {}, 3)
      if s then
        -- связь появилась или модуль/радио переехали: записать, откуда теперь считается зона связи
        local rs = {}
        for _, r in ipairs(s.radios or {}) do rs[#rs + 1] = (r.ender and "ender" or tostring(r.range)) .. "@" .. tostring(r.x) .. "," .. tostring(r.z) end
        local where = ("NAV at %s %s %s, radios [%s]"):format(tostring(s.x), tostring(s.y), tostring(s.z), table.concat(rs, " "))
        if nav == nil or where ~= nav_where then
          util.log("I", "nav: link ok, %s", where)
          ui.log_line("штурманский модуль: связь есть")
        end
        nav, nav_fail, nav_where = s, 0, where
        sync_proxy()
      else
        nav_fail = nav_fail + 1
        if nav_fail == 2 then ui.log_line("штурманский модуль: нет связи"); util.log("W", "nav: %s", tostring(err)) end
        if nav_fail >= 2 then nav = nil end   -- модуль упакован или без связи: не держать устаревший статус
      end
    end
    if tick % 3 == 0 then
      local msg = quests.tick()
      if msg then say(msg); save_state() end
    end
    sleep(10)
  end
end

-- Кто у терминала и кто онлайн (детектор игроков; запасной вариант — TM-NAV).
local function watcher()
  local n = 0
  while true do
    if n % 10 == 0 then
      who.refresh(function()
        local r = link.call("players", {}, 3)
        return r and r.names
      end)
    end
    if not who.manual then
      local sp = who.resolve(state.last_speaker)
      if sp ~= ui.data.speaker then ui.data.speaker = sp; os.queueEvent("tmai_ui", "speaker") end
    end
    n = n + 1
    sleep(1)
  end
end

local function ambience()
  local last_dawn_day = -1
  while true do
    sleep(30)
    local ep = lore.epilogue()
    local t = os.time()  -- 0..24 игровые часы
    if ep == "b" then
      if t >= 6 and t < 7 and os.day() ~= last_dawn_day then
        last_dawn_day = os.day()
        if math.random() < 0.34 then
          feed.add("ai", "…", math.random() < 0.8 and "ДОБРОЕ УТРО. СЕГОДНЯ ВСПОМНИЛИ ЕЩЁ ТРОЕ." or "ОНА ПЕРЕДАЁТ: НЕ ЗАБЫВАЙТЕ ЕСТЬ.")
        end
      end
    elseif not ep and cfg.hum and lore.level() >= 4 and (t >= 22 or t < 4) and util.now() - last_talk_t > 300 and #queue == 0 then
      if math.random() < 0.15 and extras.hum(lore.level() >= 9) then
        say("Простите. Задумался.")
      end
    end
  end
end

-- ---------- данные для экранов ----------
local function memory_rows()
  local rows = { { text = "Восстановленная память", header = true } }
  for _, l in ipairs(lore.layers_open()) do
    rows[#rows + 1] = { text = "Сектор " .. l.n .. ": «" .. l.title .. "»", fg = colors.white, row = { kind = "read", what = "layer", n = l.n } }
  end
  local finds = lore.list()
  rows[#rows + 1] = { text = "Находки в Ящике памяти", header = true }
  for _, f in ipairs(finds) do
    rows[#rows + 1] = { text = "«" .. f.title .. "»" .. (f.restored and "" or " — без контекста"),
      fg = f.restored and colors.white or colors.gray, row = { kind = "read", what = "find", item = f.item } }
  end
  if #finds == 0 then rows[#rows + 1] = { text = "пусто: кладите записки и носители в Ящик памяти", fg = colors.gray } end
  rows[#rows + 1] = { text = "Заметки ЛОЦМАНа", header = true }
  local notes = history.notes()
  for i, nt in ipairs(notes) do
    rows[#rows + 1] = { text = i .. ". " .. nt.text, fg = colors.lightGray, row = { kind = "read", what = "note", i = i } }
  end
  if #notes == 0 then rows[#rows + 1] = { text = "нет (попросите: «запомни, что…»)", fg = colors.gray } end
  return rows
end

local function read_memory(row)
  if row.what == "layer" then
    local rec, title = lore.record(row.n)
    return "Сектор " .. row.n .. ": «" .. tostring(title) .. "»", rec
  elseif row.what == "find" then
    for _, f in ipairs(lore.list()) do
      if f.item == row.item then return "«" .. f.title .. "»", (lore.memory_read(f.item)) end
    end
  elseif row.what == "note" then
    local nt = history.notes()[row.i]
    if nt then return "Заметка " .. row.i .. (nt.by and (" (" .. nt.by .. ")") or ""), nt.text end
  end
  return "?", "(нет текста)"
end

local function modem_kind(name)
  local ok, wl = pcall(peripheral.call, name, "isWireless")
  if not ok then return "модем" end
  return wl and "беспроводной/эндер" or "проводной"
end

local function device_rows(p)
  local rows = { { text = "Питание", header = true } }
  if not p.energy then
    rows[#rows + 1] = { text = "Ядро ИИ", value = "не найдено", fg = colors.red, desc = "Поставьте ядро ИИ вплотную к терминалу (лучше под ним)." }
  else
    rows[#rows + 1] = { text = "Ядро ИИ", value = p.far and "не вплотную!" or (p.pct .. "%, " .. p.energy .. " FE"),
      fg = p.far and colors.red or colors.white, desc = p.far and "Ядро должно стоять вплотную к терминалу: нагрузка «думаю» идёт сигналом." or "Генератор или любой кабель FE подключайте к ядру." }
  end
  rows[#rows + 1] = { text = "Экраны и звук", header = true }
  local mname = ui.monitor_name()
  if mname then
    local mw, mh = peripheral.call(mname, "getSize")
    rows[#rows + 1] = { text = "Монитор", value = mname .. " " .. mw .. "×" .. mh, desc = "Любой продвинутый монитор от 2×1 — вплотную или через проводной модем." }
  else
    rows[#rows + 1] = { text = "Монитор", value = "нет", fg = colors.orange, desc = "Поставьте продвинутый монитор 2×1 (или больше) рядом или подключите модемом." }
  end
  rows[#rows + 1] = { text = "Детектор игроков", value = who.present() and "есть" or "нет", fg = who.present() and colors.white or colors.gray,
    desc = who.present() and "По нему ЛОЦМАН узнаёт, кто говорит у терминала."
      or "Нет в сети: ПКМ дважды по проводному модему рядом с детектором (выкл/вкл). Пока — щёлкните по имени в строке ввода." }
  rows[#rows + 1] = { text = "Колонка", value = peripheral.find("speaker") and "есть" or "нет" }
  rows[#rows + 1] = { text = "Принтер", value = peripheral.find("printer") and "есть" or "нет", desc = "Если есть — печатает восстановленные записи." }
  rows[#rows + 1] = { text = "Ящик памяти", header = true }
  local _, boxname = memory_box()
  for _, inv in ipairs(inventories()) do
    local cur = inv == boxname
    rows[#rows + 1] = { text = inv, value = cur and "Ящик памяти" or (SIDE[inv] and "вплотную" or "в сети"),
      fg = cur and colors.lime or colors.white, row = { kind = "inv" },
      action = not cur and { kind = "memory_box", name = inv, label = "сделать Ящиком памяти" } or nil,
      desc = cur and "Сюда кладут записки и детали ремонта." or "Enter — сделать этот инвентарь Ящиком памяти." }
  end
  if not boxname then rows[#rows + 1] = { text = "нет: поставьте сундук рядом с терминалом", fg = colors.orange } end
  rows[#rows + 1] = { text = "Связь", header = true }
  rows[#rows + 1] = { text = "Штурманский модуль", value = nav and ("на связи, ремонт " .. (nav.repair or 0) .. "/4") or "нет связи",
    fg = nav and colors.white or colors.orange, desc = "TM-NAV: проводной модем/кабель, беспроводной или эндер-модем." }
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "modem") then rows[#rows + 1] = { text = "Модем " .. n, value = modem_kind(n) } end
  end
  rows[#rows + 1] = { text = "Прокси", value = config.proxy_label(state.proxy_sent),
    desc = "Для запросов в интернет, если сайт недоступен напрямую: «Настройки» → proxy. Домашняя сеть — напрямую." }
  rows[#rows + 1] = { text = "МЭ-мост", value = me.attach() and "в сети" or "нет", desc = "ME Bridge рядом с терминалом или в сети — ЛОЦМАН видит склад и заказывает автокрафт." }
  rows[#rows + 1] = { text = "КПК на связи", value = tostring(#pdas_recent()) }
  rows[#rows + 1] = { text = "Компьютеры с tmexec", value = tostring(#scripts.list_targets()) }
  if build and build.list_builders then
    local okb2, bl = pcall(build.list_builders)
    rows[#rows + 1] = { text = "Черепашки-строители", value = tostring(okb2 and bl and #bl or 0),
      desc = "Черепашка с меткой TM-BUILD-… (или программа tmbuild), сундук с блоками — позади неё." }
  end
  return rows
end

local function ui_loop()
  local n = 0
  while true do
    local p = power.status()
    ui.data.status = {
      name = persona_name(), power = p, llm = llm_status, llm_ready = config.check(cfg),
      search = embed.state == "ready" and "по смыслу" or (embed.state == "building" and ("строю " .. embed.progress)
        or (embed.state == "error" and "по словам (сбой)" or "по словам")),
      me = me.attach(), nav = nav ~= nil, repair = nav and nav.repair,
      radio = nav and nav.radio and (nav.radio.ender and "эндер" or (tostring(nav.radio.range) .. " бл.")) or "?",
      queue = #queue + (working and 1 or 0),
    }
    ui.data.busy = working
    ui.data.quests = { active = quests.active(), available = quests.available(nav and nav.repair or 0) }
    ui.data.memory = memory_rows()
    ui.data.alerts = alert.list()
    if n % 5 == 0 then
      local okd, rows = pcall(device_rows, p)
      ui.data.devices = okd and rows or { { text = "ошибка: " .. tostring(rows), fg = colors.red } }
    end
    n = n + 1
    pcall(ui.draw_term)
    local okm, err = pcall(ui.draw_monitor, cfg)
    if not okm then util.log("W", "monitor: %s", tostring(err)) end
    local t = os.startTimer(working and 0.5 or 2)
    repeat
      local e, a = os.pullEvent()
    until (e == "timer" and a == t) or e == "tmai_ui"
  end
end

-- Векторы справочника («поиск по смыслу»). Готовый индекс лежит на диске — повторная сборка с тем же
-- справочником и моделью мгновенная. Не вышло (нет сети, сайт закрыт, прокси ещё не включён) — повтор через
-- 1, 2, 4… до 15 минут; смена настроек или включение прокси (событие tmai_embed) — сразу.
local function embedder()
  local wait = 60
  while true do
    if embed.enabled() then
      local frags, h = kb.fragments()
      embed.build(frags, h)
      if embed.state == "ready" then wait = 60 end
    end
    local t = os.startTimer(embed.state == "error" and wait or 3600)
    repeat
      local e, a = os.pullEvent()
    until (e == "timer" and a == t) or e == "tmai_embed"
    if embed.state == "error" then wait = math.min(wait * 2, 900) end
  end
end

function App.run()
  config.define()
  cfg = config.get()
  util.set_debug(cfg.debug)
  if not fs.exists(util.DATA_DIR) then fs.makeDir(util.DATA_DIR) end
  state = util.load_json(STATE_PATH, {})
  state.seen_items = state.seen_items or {}
  power.configure(cfg); power.attach()
  me.attach(); link.attach(); open_rednet(); extras.attach(); who.attach()
  history.init(cfg.history_chars)
  lore.init(state)
  guard.init(state)
  quests.init(state, memory_box, core_name, function()
    local p = who.resolve(state.last_speaker)
    return who.valid(p) and p or nil
  end)
  embed.configure(cfg); tts.configure(cfg)
  prompt.load()
  ui.reader = read_memory
  ui.build = build
  alert.init(state, alarm, save_state)
  apps.load({
    cfg = function() return cfg end, say = say, alert = alert, me = me,
    nav = function(op, args, timeout) return link.call(op, args, timeout) end,
    speaker = function() local sp = ui.data.speaker; return who.valid(sp) and sp or nil end,
    online = function() return who.online() end,
    kpk = kpk_send,
  })
  ui.set_apps(apps)
  do
    local names = {}
    for _, a in ipairs(apps.list) do names[#names + 1] = a.id .. (a.broken and "(!)" or "") end
    util.log("I", "apps: %s", #names > 0 and table.concat(names, ",") or "нет")
  end
  os.pullEvent = (cfg.pin or "") ~= "" and os.pullEventRaw or PULL_EVENT
  math.randomseed(os.epoch("utc"))
  local ok, why = config.check(cfg)
  ui.log_line(ok and "готов" or why)
  util.log("I", "start: kb=%d sections, memory level=%d, %s, detector=%s, speaker=%s", kb.count(), lore.level(),
    ok and "llm configured" or why, who.attach() and "yes" or "no", peripheral.find("speaker") and "yes" or "no")
  if not state.greeted or not state.greeted_screen then
    local first = not state.greeted
    state.greeted, state.greeted_screen = true, true
    save_state()
    if first then say("…перезагрузка… " .. (lore.record(0) or "")) end
    say("Экипаж, говорить со мной — здесь, на терминале капсулы (ПКМ по компьютеру), или с КПК. " ..
      "На «Главной» — тревоги и все программы; вкладки сверху (Tab), начните печатать — и вы в чате.", "sys")
  end
  term.clear()
  parallel.waitForAny(listener, worker, poller, watcher, ambience, ui_loop, embedder, apps.loop, tts.loop)
end

return App
