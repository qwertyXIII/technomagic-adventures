-- tmai.app — главный цикл ЛОЦМАНа (компьютер капсулы, метка TM-AI).
-- Корутины (parallel):
--   listener — все события: чат, rednet (КПК, вышки, агенты программ), модемы, МЭ;
--   worker   — очередь: вопросы к нейросети, чтение находок, исправление программ;
--   poller   — Ящик памяти (находки, ключи слоёв, детали ремонта), поручения, статус штурманского модуля;
--   ambience — напевание ночью, утренние строки после финала;
--   ui       — экран терминала и монитор;  embedder — фоновое построение векторов базы знаний.
-- Всё, что модель может «сделать», проходит через tools.lua (белый список) и штурманский модуль TM-NAV.

local config = require("tmai.config")
local util = require("tmai.util")
local u8 = require("tmai.u8")
local chat = require("tmai.chat")
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
local extras = require("tmai.extras")

local App = {}

local cfg, state
local queue = {}
local nav = nil                -- статус TM-NAV: { x,y,z,dim, repair, radio }
local llm_status = "?"
local last_chat_t = 0          -- когда в последний раз говорили (для напевания)
local STATE_PATH = util.DATA_DIR .. "/state.json"

local function save_state() util.save_json(STATE_PATH, state) end

local function push(job)
  queue[#queue + 1] = job
  os.queueEvent("tmai_queue")
end

-- ---------- имя и голос по режиму ----------
local function persona_name()
  local ep = lore.epilogue()
  if ep == "b" then return "ШТУРМАН-4" end
  if ep == "c" then return "МАРА" end
  return "ЛОЦМАН"
end

local function say(text, player)
  chat.configure(persona_name(), cfg.chat_bytes)
  last_chat_t = util.now()
  return chat.say(text, player)
end

-- ---------- периферия ----------
local function core_name()
  local core = peripheral.find("kubejs:ai_core")
  return core and peripheral.getName(core) or nil
end

-- Ящик памяти: первый инвентарь рядом, который не ядро
local function memory_box()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "inventory") and not peripheral.hasType(name, "kubejs:ai_core") then
      return peripheral.wrap(name), name
    end
  end
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
    say(text, job.player)       -- экран КПК не рисует кириллицу: дублируем лично в чат
  elseif job.via == "chat" then
    say(text, job.hidden and job.player or nil)
  end
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
  parts[#parts + 1] = "время в мире: " .. textutils.formatTime(os.time(), true) .. ", день " .. os.day()
  return table.concat(parts, "\n")
end

local function players_text(asker)
  local names = {}
  local ok, r = pcall(link.call, "players", {}, 3)
  if ok and r and r.names then names = r.names end
  return (#names > 0 and table.concat(names, ", ") or "(неизвестно)") .. "\nСейчас спрашивает: " .. tostring(asker)
end

local function ctx_for(player)
  return {
    player = player, cfg = cfg, lore_level = lore.level(), repair = nav and nav.repair or 0,
    has_me = me.attach(), has_nav = nav ~= nil, has_exec = #scripts.list_targets() > 0,
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
local function build_context(question, player, p)
  local kbtext = kb.context_for(question, lore.level(), cfg.kb_chars)
  return "СОСТОЯНИЕ\n" .. status_text(p) ..
    "\n\nИГРОКИ ОНЛАЙН\n" .. players_text(player) ..
    "\n\nСПРАВКА (подобрана по вопросу)\n" .. (kbtext ~= "" and kbtext or "(по этому вопросу в справочнике ничего не найдено)")
end

local function new_conv_id()
  state.conv_id = ("tm-%d-%d"):format(os.getComputerID(), os.epoch("utc"))
  save_state()
end

-- Ошибки связи — «в образе».
local function error_phrase(code)
  if code == 401 or code == 403 then return "[ошибка авторизации логического ядра] Хозяину мира: проверьте ключ на терминале капсулы (set tmai.api_key …)." end
  if code == 429 then return "[канал перегружен] Слишком много запросов — повторите через минуту." end
  if code == 502 or code == 503 or code == 504 or code == nil then return "[помехи] Нет связи с логическим ядром. Повторите позже." end
  if code == 404 then return "[сбой] Логическое ядро не отвечает на этот адрес — проверьте tmai.model и tmai.base_url." end
  return "[сбой обработки запроса] Попробуйте сформулировать иначе."
end

local function compact_history()
  if not history.needs_compaction() then return end
  local done = history.compact(function(old, prev)
    return llm.simple(cfg,
      "Ты сжимаешь журнал разговора экипажа с бортовым ассистентом. Пиши по-русски, сухо, до 1200 символов: " ..
      "кто что спрашивал, договорённости, найденные места и координаты, незавершённые дела. Без воды.",
      "Предыдущая сводка:\n" .. (prev ~= "" and prev or "(нет)") .. "\n\nНовый фрагмент журнала:\n" .. old)
  end)
  if done then new_conv_id() end -- история переписана: шлюз должен начать новую сессию
end

-- ---------- задания очереди ----------
local function handle_ask(job)
  local p = power.status()
  if not p.ok then
    reply(job, "[аварийный режим] Питание ядра ниже минимума. Загрузите топливо в генератор под терминалом.")
    return
  end
  local ready, why = config.check(cfg)
  if not ready then
    reply(job, "[нет связи с логическим ядром] Требуется настройка терминала капсулы.")
    ui.log_line(why)
    return
  end
  if job.via == "chat" then
    local inside = guard.in_zone(cfg, job.player, nav)
    if not inside then
      chat.configure("скафандр", cfg.chat_bytes)
      chat.say("Нет сигнала капсулы: вы вне зоны связи. Нужна вышка-ретранслятор или КПК.", job.player)
      return
    end
  end
  if job.text == "" then
    reply(job, "Слушаю, " .. job.player .. ".")
    return
  end
  power.thinking(true)
  local ctx = ctx_for(job.player)
  if not state.conv_id then new_conv_id() end
  local answer, err, code = llm.ask({
    cfg = cfg, system = build_system(), history = history.messages(),
    user = job.text, user_name = job.player, context = build_context(job.text, job.player, p),
    conv_id = state.conv_id, tools = tools.available(ctx),
    run_tool = function(name, args) return tools.run(name, args, ctx) end,
  })
  power.thinking(false)
  if not answer then
    llm_status = "error"
    util.log("E", "llm: %s", tostring(err))
    ui.log_line("LLM error: " .. tostring(err):sub(1, 60))
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
      sleep(1.1)
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
  local answer = llm.ask({
    cfg = cfg, system = build_system(), context = build_context("скрипт lua cc tweaked ошибка", job.player, power.status()),
    history = {}, user = job.text, user_name = job.player, tools = tools.available(ctx),
    run_tool = function(name, args) return tools.run(name, args, ctx) end,
  })
  if answer and answer ~= "" then say(answer, job.player) end
end

local function handle_relay_setup(job)
  local r, err = link.call("relay_probe", { player = job.player, relay = job.sender }, 10)
  if r then
    guard.relay_register(job.sender, r)
    save_state()
    rednet.send(job.sender, { op = "relay_ok", info = r }, "tmai_relay_setup")
    say(("Вышка #%d на связи: %s"):format(job.sender, r.ender and "эндер-модем, без ограничений" or ("дальность " .. r.range .. " блоков")), job.player)
  else
    rednet.send(job.sender, { op = "relay_fail", error = tostring(err) }, "tmai_relay_setup")
  end
end

local function worker()
  while true do
    if #queue == 0 then os.pullEvent("tmai_queue") end
    local job = table.remove(queue, 1)
    if job then
      local ok, err = pcall(function()
        if job.kind == "ask" then handle_ask(job)
        elseif job.kind == "memory" then handle_memory(job)
        elseif job.kind == "fix" then handle_fix(job)
        elseif job.kind == "relay_setup" then handle_relay_setup(job)
        end
      end)
      power.thinking(false)
      if not ok then util.log("E", "job %s failed: %s", tostring(job.kind), tostring(err)) end
      pcall(compact_history)
    end
  end
end

-- ---------- детерминированные команды чата (без нейросети) ----------
local function direct_command(player, text)
  local low = u8.lower(text)
  local code, auto = low:match("^да%s+(%d%d%d)%s*(%S*)")
  if code then
    if scripts.is_job(code) then
      local j = scripts.confirm(code, auto == "авто")
      say(j and ("Запускаю " .. j.name .. " на компьютере #" .. j.target .. ".") or "Нет такой программы.", player)
    else
      local r, err = me.confirm(code, player)
      say(r and ("Заказ принят: " .. r.item .. " x" .. r.count .. ".") or ("Не выполнено: " .. tostring(err)), player)
    end
    return true
  end
  local stop = low:match("^стоп%s*(%d*)$")
  if stop then
    local n = scripts.stop(stop ~= "" and stop or nil)
    say("Остановлено программ: " .. n, player)
    return true
  end
  return false
end

local function listener()
  while true do
    local ev = { os.pullEvent() }
    local name = ev[1]
    if name == "chat" then
      local m = chat.parse(ev)
      if m then
        local hit, rest = u8.strip_trigger(m.text, cfg.trigger_list)
        if hit then
          last_chat_t = util.now()
          if not direct_command(m.name, rest) then
            local ok, why = guard.allow(cfg, m.name, rest, #queue)
            if ok then
              push({ kind = "ask", player = m.name, text = u8.truncate(rest, cfg.max_input * 2), via = "chat", hidden = m.hidden })
            elseif why ~= "слишком часто" then
              say("[" .. why .. "]", m.name)
            end
          end
        elseif u8.lower(m.text):match("^да%s+%d%d%d") or u8.lower(m.text):match("^стоп") then
          direct_command(m.name, m.text)
        end
      end
    elseif name == "modem_message" then
      link.on_modem_message(ev[2], ev[3], ev[4], ev[5], ev[6])
    elseif name == "rednet_message" then
      local sender, msg, proto = ev[2], ev[3], ev[4]
      if proto == link.RADIO and type(msg) == "table" and msg.op == "ask" and type(msg.text) == "string" then
        local player = tostring(msg.player or ("КПК#" .. sender))
        if not player:match("^[%w_]+$") then player = "КПК" .. sender end
        local ok, why = guard.allow(cfg, player, msg.text, #queue)
        if ok then push({ kind = "ask", player = player, text = u8.truncate(msg.text, cfg.max_input * 2), via = "radio", reply_to = sender })
        else rednet.send(sender, { op = "answer", text = "[" .. why .. "]" }, link.RADIO) end
      elseif proto == link.RADIO and type(msg) == "table" and msg.op == "ping" then
        rednet.send(sender, { op = "pong", from = persona_name() }, link.RADIO)
      elseif proto == "tmai_relay" and type(msg) == "table" and msg.op == "relay_hb" then
        guard.relay_beacon(sender)
      elseif proto == "tmai_relay_setup" and type(msg) == "table" and msg.op == "setup" and type(msg.player) == "string" then
        push({ kind = "relay_setup", sender = sender, player = msg.player })
      elseif proto == scripts.PROTO then
        local j, m = scripts.on_rednet(sender, msg)
        if j and m.state == "error" then
          say("Программа " .. j.name .. " упала: " .. tostring(m.error):sub(1, 200), j.player)
          if j.auto and (j.fixes or 0) < 3 then push({ kind = "fix", player = j.player, text = scripts.fix_prompt(j) }) end
        elseif j and m.state == "done" then
          say("Программа " .. j.name .. " завершена.", j.player)
        end
      end
    elseif name == "ae_crafting" then
      local text = me.on_event(ev[2], ev[3], ev[4])
      if text then say(text) end
    elseif name == "peripheral" or name == "peripheral_detach" then
      chat.attach(); power.attach(); me.attach(); link.attach(); open_rednet(); extras.attach()
    end
  end
end

-- ---------- периодические проверки ----------
local REPAIR_PARTS = {}
for _, r in ipairs(util.read_tsv(util.ROM_DIR .. "/repair.tsv")) do REPAIR_PARTS[r.item] = true end

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
      local s = link.call("status", {}, 3)
      if s then nav = s end
    end
    if tick % 3 == 0 then
      local msg = quests.tick()
      if msg then say(msg); save_state() end
    end
    sleep(10)
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
          chat.configure("…", cfg.chat_bytes)
          chat.say(math.random() < 0.8 and "ДОБРОЕ УТРО. СЕГОДНЯ ВСПОМНИЛИ ЕЩЁ ТРОЕ." or "ОНА ПЕРЕДАЁТ: НЕ ЗАБЫВАЙТЕ ЕСТЬ.")
        end
      end
    elseif not ep and cfg.hum and lore.level() >= 4 and (t >= 22 or t < 4) and util.now() - last_chat_t > 300 and #queue == 0 then
      if math.random() < 0.15 and extras.hum(lore.level() >= 9) then
        say("Простите. Задумался.")
      end
    end
  end
end

local function ui_loop()
  while true do
    ui.render({
      power = power.status(), llm = llm_status, llm_ok = llm_status == "ok",
      tools = llm.tools_supported == false and "unsupported" or (cfg.use_tools and "on" or "off"),
      search = embed.state == "ready" and "vector+kw" or (embed.state == "building" and ("building " .. embed.progress) or "keywords"),
      me = me.attach(), nav = nav ~= nil, repair = nav and nav.repair,
      radio = nav and nav.radio and (nav.radio.ender and "ender" or tostring(nav.radio.range)) or "?",
      queue = #queue,
    })
    sleep(2)
  end
end

local function embedder()
  if embed.enabled() then
    local frags, h = kb.fragments()
    embed.build(frags, h)
  end
  while true do os.pullEvent("tmai_never") end
end

function App.run()
  config.define()
  cfg = config.get()
  util.set_debug(cfg.debug)
  if not fs.exists(util.DATA_DIR) then fs.makeDir(util.DATA_DIR) end
  state = util.load_json(STATE_PATH, {})
  state.seen_items = state.seen_items or {}
  chat.configure(persona_name(), cfg.chat_bytes)
  chat.attach()
  power.configure(cfg); power.attach()
  me.attach(); link.attach(); open_rednet(); extras.attach()
  history.init(cfg.history_chars)
  lore.init(state)
  guard.init(state)
  quests.init(state, memory_box, core_name)
  embed.configure(cfg); tts.configure(cfg)
  prompt.load()
  math.randomseed(os.epoch("utc"))
  local ok, why = config.check(cfg)
  ui.log_line(ok and "ready" or why)
  util.log("I", "start: kb=%d sections, memory level=%d, %s", kb.count(), lore.level(), ok and "llm configured" or why)
  if not state.greeted then
    state.greeted = true
    save_state()
    say("…перезагрузка… " .. (lore.record(0) or ""))
    say("Экипаж, чтобы говорить со мной, начните сообщение со слова «Лоцман».")
  end
  parallel.waitForAny(listener, worker, poller, ambience, ui_loop, embedder)
end

return App
