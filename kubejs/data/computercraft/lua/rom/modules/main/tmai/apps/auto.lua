-- tmai.apps.auto — «Сценарии»: правила «когда → [если] → что сделать» без нейросети. Только данные (ДЕКЛАРАТИВНО):
-- код нейросети внутри ЛОЦМАНа не исполняется; всё сложное — Lua-программа на другом компьютере (tmexec), с которой
-- сценарии обмениваются событиями (rednet-протокол tmai_event: { name = "lockdown", data = …, from = "locman" }).
--
-- Сценарий (ctx.data.rules[i]; так же его даёт инструмент auto_add — см. справочник pack.auto):
--   { id, name, on = включён, when = {type=…}, cond = {{type=…}…} (conditions), acts = {{type=…}…} (actions),
--     cooldown = с (не чаще), reply = ответ на фразу, by = кто создал, by_ai = создал ИИ, last/runs/last_err… }
-- КОГДА (when.type): redstone {switch | device+side, edge on|off|any} · phrase {text, exact=true, from} ·
--   time {at = morning|noon|evening|night|midnight|"ЧЧ:ММ" — время Minecraft} · every {minutes} ·
--   alert {key = "base.energy" | "storage.low.*" | "any", edge raise|clear} · player {event arrive|leave, player,
--   range = 16 (0 — вход/выход с сервера)} · event {name, from = id компьютера} · manual.
-- ЕСЛИ (conditions): night · day · online {player} · offline {player} · switch {name, state on|off}.
-- ЧТО (actions, по порядку): switch {name|group, state on|off|toggle|pulse} · lock / unlock {name|group} ·
--   say {text} (лента, КПК, озвучка) · kpk {text, player} · alert {text, level | clear} · event {name, data, to} ·
--   program {program = код|имя, op run|stop} · wait {seconds} · run / enable / disable {scenario} · give {item, count}.
-- Защита от петель: сценарий не чаще cooldown (по умолчанию 2 с), цепочка сценариев (run, тревога сценария → другой
-- сценарий) — не глубже 3, всего не больше 30 запусков в минуту. Сценарий ИИ (auto_add) не трогает переключатели
-- «только вручную» — такие делает игрок сам на вкладке.
-- Фразы: app.lua до нейросети зовёт A.on_phrase(ctx, text, player, via) -> handled, ответ
--   (сработал сценарий — ответить и в нейросеть не слать; «запусти/включи/выключи сценарий X» — тоже здесь).
-- Вкладка (свой вид): список (Enter — подробности и кнопки Запустить/Выключить/Удалить), «+ сценарий» — мастер
-- на 1 «когда» и 1–3 действия. Инструменты ИИ: auto_add, auto_list, auto_remove, auto_enable, auto_run.
-- КПК: radio list / run.

local text = require("tmai.text")
local u8 = require("tmai.u8")
local util = require("tmai.util")
local json = require("tmai.json")
local input = require("tmai.input")
local scripts = require("tmai.scripts")

local A = { id = "auto", title = "Сценарии", short = "Сцен", order = 55, every = 5 }

local MAX_RULES, MAX_ACTS, MAX_COND = 40, 12, 4
local MAX_DEPTH = 3          -- цепочка сценариев: A → B → C, дальше — нет
local GAP = 2                -- сценарий не чаще раза в GAP с (по умолчанию)
local RATE = 30              -- всего запусков в минуту
local WAIT_MAX = 600
local NAME_MAX = 32
local SIDES = { top = "верх", bottom = "низ", left = "лево", right = "право", front = "перед", back = "зад" }
local SIDE_LIST = { "top", "bottom", "left", "right", "front", "back" }
local TIMES = { morning = 6, noon = 12, evening = 18, night = 19, midnight = 0 }
local TIME_RU = { morning = "утро", noon = "полдень", evening = "вечер", night = "ночь", midnight = "полночь" }

-- состояние движка (не сохраняется): запуски, прошлые значения триггеров
local E

local function reset_engine()
  E = { runs = {}, last_start = {}, starts = {}, rs = {}, players = {}, players_t = -100, alerts = nil,
    alert_depth = {}, time_abs = nil, every_t = {}, primed = false, stepping = false, rate_warned = -100,
    log = {}, last_rs_poll = -100 }
end
reset_engine()

local V = { mode = "list", sel = {}, top = {} }   -- вид терминала

-- ---------------------------------------------------------------- общее

local function reg() return require("tmai.apps") end

local function panel()
  local p = reg().get("panel")
  if p and p.api and p.ctx and not p.broken then return p.api end
  return nil
end

local function rules(ctx)
  if type(ctx.data.rules) ~= "table" then ctx.data.rules = {} end
  return ctx.data.rules
end

local function norm(s) return u8.lower(u8.trim(tostring(s or ""))) end

local function by_id(ctx, id)
  id = tonumber(id)
  for i, r in ipairs(rules(ctx)) do if r.id == id then return r, i end end
  return nil
end

local function by_name(ctx, name)
  local q = norm(name)
  if q == "" then return nil end
  for _, r in ipairs(rules(ctx)) do if norm(r.name) == q then return r end end
  local hit, n = nil, 0
  for _, r in ipairs(rules(ctx)) do if norm(r.name):find(q, 1, true) then hit, n = r, n + 1 end end
  if n == 1 then return hit end
  return nil
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

local function is_nick(s) return type(s) == "string" and #s >= 3 and #s <= 16 and s:match("^[%w_]+$") ~= nil end

local function ago(t, short)
  if not t then return short and "" or "ещё не срабатывал" end
  local d = util.now() - (tonumber(t) or 0)
  local s
  if d < 60 then return short and "сейчас" or "только что"
  elseif d < 3600 then s = math.floor(d / 60) .. " мин"
  elseif d < 86400 then s = math.floor(d / 3600) .. " ч"
  else s = math.floor(d / 86400) .. " дн" end
  return short and s or (s .. " назад")
end

local function hours_text(h)
  local hh = math.floor(h)
  local mm = math.floor((h - hh) * 60 + 0.5)
  if mm >= 60 then hh, mm = hh + 1, 0 end
  return string.format("%d:%02d", hh % 24, mm)
end

local function remember(line)
  E.log[#E.log + 1] = textutils.formatTime(os.time(), true) .. " " .. line
  while #E.log > 30 do table.remove(E.log, 1) end
end

-- ---------------------------------------------------------------- описание словами

local EDGE_RU = { on = "включился", off = "выключился", any = "изменился" }

local function desc_when(w)
  if not w then return "?" end
  local t = w.type
  if t == "redstone" then
    local src = w.switch and ("«" .. w.switch .. "»")
      or ((w.device == "self" and "компьютер ИИ" or tostring(w.device)) .. " · " .. tostring(SIDES[w.side] or w.side))
    return "сигнал " .. src .. " " .. (EDGE_RU[w.edge] or "включился")
  elseif t == "phrase" then
    return "фраза «" .. tostring(w.text) .. "»" .. (w.exact == false and " (в тексте)" or "") .. (w.from and (" от " .. w.from) or "")
  elseif t == "time" then
    return "в " .. hours_text(w.hour or 0) .. (w.at and TIME_RU[w.at] and (" (" .. TIME_RU[w.at] .. ")") or "")
  elseif t == "every" then
    return "каждые " .. tostring(w.minutes) .. " мин"
  elseif t == "alert" then
    local k = (w.key == "any") and "любая тревога" or ("тревога " .. tostring(w.key))
    return (w.edge == "clear" and "снята: " or "") .. k
  elseif t == "player" then
    local who = w.player or "любой игрок"
    local ev = w.event == "leave" and (w.range == 0 and "вышел с сервера" or "ушёл") or (w.range == 0 and "зашёл на сервер" or "пришёл")
    return who .. " " .. ev .. ((w.range or 0) > 0 and (" (" .. w.range .. " бл.)") or "")
  elseif t == "event" then
    return "событие «" .. tostring(w.name) .. "»" .. (w.from and (" от #" .. w.from) or "")
  elseif t == "manual" then
    return "вручную"
  end
  return tostring(t)
end

local function desc_cond(c)
  if c.type == "night" then return "ночью"
  elseif c.type == "day" then return "днём"
  elseif c.type == "online" then return c.player .. " в игре"
  elseif c.type == "offline" then return c.player .. " не в игре"
  elseif c.type == "switch" then return "«" .. tostring(c.name) .. "» " .. (c.state == "off" and "выкл" or "вкл") end
  return tostring(c.type)
end

local STATE_RU = { on = "вкл", off = "выкл", toggle = "переключить", pulse = "импульс" }

local function target_text(a) return a.group and ("группа «" .. a.group .. "»") or ("«" .. tostring(a.name) .. "»") end

local function desc_act(a)
  local t = a.type
  if t == "switch" then return target_text(a) .. ": " .. (STATE_RU[a.state] or tostring(a.state))
  elseif t == "lock" then return "заблокировать " .. target_text(a)
  elseif t == "unlock" then return "разблокировать " .. target_text(a)
  elseif t == "say" then return "сказать «" .. tostring(a.text) .. "»"
  elseif t == "kpk" then return "на КПК" .. (a.player and (" " .. a.player) or "") .. ": «" .. tostring(a.text) .. "»"
  elseif t == "alert" then return a.clear and "снять тревогу" or ("тревога «" .. tostring(a.text) .. "»")
  elseif t == "event" then return "событие «" .. tostring(a.name) .. "»" .. (a.to and (" для #" .. a.to) or " программам")
  elseif t == "program" then return "программа " .. tostring(a.program) .. ": " .. (a.op == "stop" and "остановить" or "запустить")
  elseif t == "wait" then return "ждать " .. tostring(a.seconds) .. " с"
  elseif t == "run" then return "сценарий «" .. tostring(a.scenario) .. "»"
  elseif t == "enable" then return "включить сценарий «" .. tostring(a.scenario) .. "»"
  elseif t == "disable" then return "выключить сценарий «" .. tostring(a.scenario) .. "»"
  elseif t == "give" then return "выдать " .. tostring(a.count) .. " × " .. tostring(a.item) end
  return tostring(t)
end

local function desc_rule(r)
  local parts = {}
  for _, a in ipairs(r.acts or {}) do parts[#parts + 1] = desc_act(a) end
  local c = {}
  for _, x in ipairs(r.cond or {}) do c[#c + 1] = desc_cond(x) end
  return desc_when(r.when) .. (#c > 0 and (" [" .. table.concat(c, ", ") .. "]") or "") .. " → " .. table.concat(parts, "; ")
end

-- В формат инструмента (как его даёт auto_add).
local function export(r)
  return { name = r.name, enabled = r.on and true or false, when = copy(r.when),
    conditions = (#(r.cond or {}) > 0) and copy(r.cond) or nil, actions = copy(r.acts),
    cooldown = r.cooldown ~= GAP and r.cooldown or nil, reply = r.reply }
end

-- ---------------------------------------------------------------- проверка сценария (строгая, ошибки — понятные)

local function list_keys(allowed)
  local ks = {}
  for k in pairs(allowed) do ks[#ks + 1] = k end
  table.sort(ks)
  return table.concat(ks, ", ")
end

local function only_keys(t, allowed, path, errs)
  for k in pairs(t) do
    if not allowed[k] then errs[#errs + 1] = path .. ": лишнее поле «" .. tostring(k) .. "» (можно: " .. list_keys(allowed) .. ")" end
  end
end

local function f_text(v, max, path, errs, required)
  if v == nil then
    if required then errs[#errs + 1] = path .. ": нужен текст" end
    return nil
  end
  if type(v) ~= "string" and type(v) ~= "number" then errs[#errs + 1] = path .. ": нужен текст"; return nil end
  local s = u8.trim((tostring(v):gsub("[\1-\31\127]", " ")))
  if s == "" then
    if required then errs[#errs + 1] = path .. ": пустой текст" end
    return nil
  end
  if text.len(s) > max then errs[#errs + 1] = path .. ": длиннее " .. max .. " знаков"; return nil end
  return s
end

local function f_num(v, lo, hi, path, errs, required, default)
  if v == nil then
    if required then errs[#errs + 1] = path .. ": нужно число" end
    return default
  end
  local n = tonumber(v)
  if not n then errs[#errs + 1] = path .. ": нужно число"; return default end
  if n < lo or n > hi then errs[#errs + 1] = path .. ": от " .. lo .. " до " .. hi; return default end
  return n
end

local function f_enum(v, set, path, errs, default)
  if v == nil then return default end
  local s = tostring(v):lower()
  if not set[s] then errs[#errs + 1] = path .. ": одно из " .. list_keys(set); return default end
  return s
end

local function f_nick(v, path, errs, required)
  if v == nil then
    if required then errs[#errs + 1] = path .. ": нужен ник игрока" end
    return nil
  end
  if not is_nick(v) then errs[#errs + 1] = path .. ": ник — латиница, цифры, _ (3–16)"; return nil end
  return v
end

local function f_bool(v, path, errs, default)
  if v == nil then return default end
  if type(v) ~= "boolean" then errs[#errs + 1] = path .. ": true или false"; return default end
  return v
end

local WHEN_KEYS = {
  redstone = { type = 1, switch = 1, device = 1, side = 1, edge = 1 }, phrase = { type = 1, text = 1, exact = 1, from = 1 },
  time = { type = 1, at = 1 }, every = { type = 1, minutes = 1 }, alert = { type = 1, key = 1, edge = 1 },
  player = { type = 1, event = 1, player = 1, range = 1 }, event = { type = 1, name = 1, from = 1 }, manual = { type = 1 },
}
local COND_KEYS = { night = { type = 1 }, day = { type = 1 }, online = { type = 1, player = 1 }, offline = { type = 1, player = 1 },
  ["switch"] = { type = 1, name = 1, state = 1 } }
local ACT_KEYS = {
  ["switch"] = { type = 1, name = 1, group = 1, state = 1 }, lock = { type = 1, name = 1, group = 1 },
  unlock = { type = 1, name = 1, group = 1 }, say = { type = 1, text = 1 }, kpk = { type = 1, text = 1, player = 1 },
  alert = { type = 1, text = 1, level = 1, clear = 1 }, event = { type = 1, name = 1, data = 1, to = 1 },
  program = { type = 1, program = 1, op = 1 }, wait = { type = 1, seconds = 1 }, run = { type = 1, scenario = 1 },
  enable = { type = 1, scenario = 1 }, disable = { type = 1, scenario = 1 }, give = { type = 1, item = 1, count = 1 },
}
local TOP_KEYS = { name = 1, when = 1, conditions = 1, actions = 1, cooldown = 1, reply = 1, enabled = 1 }
local TOP_HINT = { ["if"] = "conditions", ["do"] = "actions", ["then"] = "actions", trigger = "when", steps = "actions",
  title = "name", enable = "enabled", condition = "conditions", action = "actions" }

local function event_name(v, path, errs)
  local s = f_text(v, 32, path, errs, true)
  if s and not s:match("^[%w_%.%-]+$") then errs[#errs + 1] = path .. ": латиница, цифры, _ . - (например lockdown)"; return nil end
  return s
end

-- name/group действия или условия -> канонический вид; проверка через «Пульт».
local function f_target(a, path, errs, by_ai, allow_lamp)
  local P = panel()
  if not P then errs[#errs + 1] = path .. ": нет приложения «Пульт»"; return nil end
  if (a.name == nil) == (a.group == nil) then errs[#errs + 1] = path .. ": нужно name (переключатель) ИЛИ group (группа)"; return nil end
  local list, why = P.resolve(a.name, a.group)
  if not list then
    errs[#errs + 1] = path .. ": " .. tostring(why) .. " (переключатели и группы — panel_list; нет нужного — игроку подключить редстоун-ретранслятор и добавить переключатель на вкладке «Пульт»)"
    return nil
  end
  for _, sw in ipairs(list) do
    if sw.kind == "lamp" and not allow_lamp then errs[#errs + 1] = path .. ": «" .. sw.name .. "» — индикатор, им нельзя управлять"; return nil end
    if by_ai and sw.manual then
      errs[#errs + 1] = path .. ": «" .. sw.name .. "» — «только вручную»: сценарий ЛОЦМАНа его не трогает (игрок может создать такой сценарий сам на вкладке «Сценарии» или разрешить переключатель на «Пульте»)"
      return nil
    end
  end
  -- имя оказалось группой («двери») — храним как группу
  local g = a.group or (not P.find(a.name) and a.name) or nil
  if g then return { group = (u8.lower(u8.trim(tostring(g))):gsub("^все%s+", "")), list = list } end
  return { name = list[1].name, list = list }
end

-- src (таблица как у auto_add) -> сценарий | nil, ошибки; предупреждения — третьим.
local function validate(ctx, src, opts)
  opts = opts or {}
  local errs, warns = {}, {}
  if type(src) ~= "table" then return nil, { "сценарий: нужен объект {name, when, actions}" } end
  for k in pairs(src) do
    if not TOP_KEYS[k] then
      errs[#errs + 1] = "лишнее поле «" .. tostring(k) .. "»" .. (TOP_HINT[k] and (" — оно называется " .. TOP_HINT[k]) or "")
        .. " (можно: " .. list_keys(TOP_KEYS) .. ")"
    end
  end
  local r = { cond = {}, acts = {} }
  r.name = f_text(src.name, NAME_MAX, "name", errs, true)
  if r.name then
    for _, o in ipairs(rules(ctx)) do
      if o.id ~= opts.except_id and norm(o.name) == norm(r.name) and not opts.replace then
        errs[#errs + 1] = "name: сценарий «" .. o.name .. "» уже есть (другое имя или replace)"
      end
    end
  end
  r.on = f_bool(src.enabled, "enabled", errs, true)
  r.cooldown = f_num(src.cooldown, 1, 3600, "cooldown", errs, false, GAP)
  r.reply = f_text(src.reply, 100, "reply", errs, false)
  -- КОГДА
  local w = src.when
  if type(w) ~= "table" then errs[#errs + 1] = "when: нужен объект {type: …}"
  else
    local t = tostring(w.type or ""):lower()
    if not WHEN_KEYS[t] then errs[#errs + 1] = "when.type: одно из " .. list_keys(WHEN_KEYS)
    else
      only_keys(w, WHEN_KEYS[t], "when", errs)
      local o = { type = t }
      if t == "redstone" then
        o.edge = f_enum(w.edge == "pulse" and "on" or w.edge, { on = 1, off = 1, any = 1 }, "when.edge", errs, "on")
        if w.switch ~= nil then
          local P = panel()
          local sw = P and P.find(w.switch)
          if not sw then errs[#errs + 1] = "when.switch: нет переключателя «" .. tostring(w.switch) .. "» на «Пульте» (индикатор входа добавляет игрок; или device+side)"
          else o.switch = sw.name end
        else
          local dev = w.device
          if dev == "computer" then dev = "self" end
          if type(dev) ~= "string" or dev == "" then errs[#errs + 1] = "when: нужно switch (индикатор «Пульта») или device + side"
          elseif dev ~= "self" and not (peripheral.hasType(dev, "redstone_relay") or peripheral.hasType(dev, "redstone_integrator")) then
            errs[#errs + 1] = "when.device: «" .. dev .. "» — не редстоун-ретранслятор в сети (или self — компьютер ИИ)"
          end
          o.device = dev
          o.side = f_enum(w.side, SIDES, "when.side", errs, nil)
          if not o.side then errs[#errs + 1] = "when.side: нужна сторона" end
        end
      elseif t == "phrase" then
        o.text = f_text(w.text, 60, "when.text", errs, true)
        o.exact = f_bool(w.exact, "when.exact", errs, true)
        o.from = f_nick(w.from, "when.from", errs, false)
        if o.text and text.len(o.text) < 2 then errs[#errs + 1] = "when.text: слишком коротко" end
        for _, x in ipairs(rules(ctx)) do
          if x.id ~= opts.except_id and x.when and x.when.type == "phrase" and o.text and norm(x.when.text) == norm(o.text) then
            warns[#warns + 1] = "та же фраза уже у сценария «" .. x.name .. "» — сработают оба"
          end
        end
      elseif t == "time" then
        local at = w.at
        if type(at) == "string" and TIMES[at:lower()] then o.at = at:lower(); o.hour = TIMES[o.at]
        elseif type(at) == "string" and at:match("^%d%d?:%d%d$") then
          local hh, mm = at:match("^(%d%d?):(%d%d)$")
          hh, mm = tonumber(hh), tonumber(mm)
          if hh > 23 or mm > 59 then errs[#errs + 1] = "when.at: время 0:00..23:59"
          else o.at = string.format("%d:%02d", hh, mm); o.hour = hh + mm / 60 end
        else errs[#errs + 1] = "when.at: morning|noon|evening|night|midnight или \"ЧЧ:ММ\" (время Minecraft)" end
      elseif t == "every" then
        o.minutes = f_num(w.minutes, 1, 1440, "when.minutes", errs, true, 10)
      elseif t == "alert" then
        o.key = f_text(w.key or "any", 40, "when.key", errs, true)
        o.edge = f_enum(w.edge, { raise = 1, clear = 1 }, "when.edge", errs, "raise")
        if o.key and o.key ~= "any" and not o.key:match("^[%w_%.]+%*?$") then errs[#errs + 1] = "when.key: ключ тревоги (base.energy), префикс со звёздочкой (storage.low.*) или any" end
      elseif t == "player" then
        o.event = f_enum(w.event, { arrive = 1, leave = 1 }, "when.event", errs, nil)
        if not o.event then errs[#errs + 1] = "when.event: arrive или leave" end
        o.player = f_nick(w.player, "when.player", errs, false)
        o.range = math.floor(f_num(w.range, 0, 64, "when.range", errs, false, 16))
      elseif t == "event" then
        o.name = event_name(w.name, "when.name", errs)
        if w.from ~= nil then o.from = math.floor(f_num(w.from, 0, 65535, "when.from", errs, false, 0)) end
      end
      r.when = o
    end
  end
  -- ЕСЛИ
  local cs = src.conditions
  if cs ~= nil then
    if type(cs) ~= "table" then errs[#errs + 1] = "conditions: нужен список"
    else
      if cs.type then cs = { cs } end
      if #cs > MAX_COND then errs[#errs + 1] = "conditions: не больше " .. MAX_COND end
      for i, c in ipairs(cs) do
        local path = "conditions[" .. i .. "]"
        local t = type(c) == "table" and tostring(c.type or ""):lower() or ""
        if not COND_KEYS[t] then errs[#errs + 1] = path .. ".type: одно из " .. list_keys(COND_KEYS)
        else
          only_keys(c, COND_KEYS[t], path, errs)
          local o = { type = t }
          if t == "online" or t == "offline" then o.player = f_nick(c.player, path .. ".player", errs, true)
          elseif t == "switch" then
            local P = panel()
            local sw = P and P.find(c.name)
            if not sw then errs[#errs + 1] = path .. ".name: нет переключателя «" .. tostring(c.name) .. "»" else o.name = sw.name end
            o.state = f_enum(c.state, { on = 1, off = 1 }, path .. ".state", errs, "on")
          end
          r.cond[#r.cond + 1] = o
        end
      end
    end
  end
  -- ЧТО СДЕЛАТЬ
  local as = src.actions
  if type(as) ~= "table" or #as == 0 then errs[#errs + 1] = "actions: нужен список действий (хотя бы одно)"
  else
    if #as > MAX_ACTS then errs[#errs + 1] = "actions: не больше " .. MAX_ACTS end
    local waits = 0
    for i, a in ipairs(as) do
      local path = "actions[" .. i .. "]"
      local t = type(a) == "table" and tostring(a.type or ""):lower() or ""
      if not ACT_KEYS[t] then errs[#errs + 1] = path .. ".type: одно из " .. list_keys(ACT_KEYS)
      else
        only_keys(a, ACT_KEYS[t], path, errs)
        local o = { type = t }
        if t == "switch" or t == "lock" or t == "unlock" then
          local tg = f_target(a, path, errs, opts.by_ai, false)
          if tg then
            o.group, o.name = tg.group, tg.name
            if t == "switch" then
              o.state = f_enum(a.state, { on = 1, off = 1, toggle = 1, pulse = 1 }, path .. ".state", errs, nil)
              if not o.state then errs[#errs + 1] = path .. ".state: on, off, toggle или pulse" end
              if o.state == "pulse" then
                for _, sw in ipairs(tg.list) do
                  if sw.kind ~= "pulse" then errs[#errs + 1] = path .. ": «" .. sw.name .. "» не импульсный — on/off/toggle"; break end
                end
              end
            end
          end
        elseif t == "say" then o.text = f_text(a.text, 200, path .. ".text", errs, true)
        elseif t == "kpk" then
          o.text = f_text(a.text, 200, path .. ".text", errs, true)
          o.player = f_nick(a.player, path .. ".player", errs, false)
        elseif t == "alert" then
          o.clear = f_bool(a.clear, path .. ".clear", errs, nil)
          if not o.clear then
            o.text = f_text(a.text, 120, path .. ".text", errs, true)
            o.level = f_enum(a.level, { info = 1, warn = 1, crit = 1 }, path .. ".level", errs, "warn")
          end
        elseif t == "event" then
          o.name = event_name(a.name, path .. ".name", errs)
          if a.data ~= nil then
            local dt = type(a.data)
            if dt == "string" then o.data = f_text(a.data, 100, path .. ".data", errs, false)
            elseif dt == "number" or dt == "boolean" then o.data = a.data
            else errs[#errs + 1] = path .. ".data: строка, число или true/false" end
          end
          if a.to ~= nil then o.to = math.floor(f_num(a.to, 0, 65535, path .. ".to", errs, false, 0)) end
        elseif t == "program" then
          o.op = f_enum(a.op, { run = 1, stop = 1 }, path .. ".op", errs, "run")
          local code, j = scripts.find_job(a.program)
          if not code then errs[#errs + 1] = path .. ".program: нет программы «" .. tostring(a.program) .. "» (код или имя из programs_list)"
          elseif o.op == "run" and not j.ran then
            errs[#errs + 1] = path .. ".program: «" .. j.name .. "» ещё не запускалась — сначала игрок подтверждает «да " .. code .. "»"
          else o.program = j.name end
        elseif t == "wait" then
          o.seconds = f_num(a.seconds, 1, WAIT_MAX, path .. ".seconds", errs, true, 1)
          waits = waits + (o.seconds or 0)
        elseif t == "run" or t == "enable" or t == "disable" then
          local name = f_text(a.scenario, NAME_MAX, path .. ".scenario", errs, true)
          if name then
            local other = by_name(ctx, name)
            if r.name and norm(name) == norm(r.name) then
              if t == "run" then errs[#errs + 1] = path .. ": сценарий не запускает сам себя" end
              o.scenario = r.name
            elseif not other then errs[#errs + 1] = path .. ".scenario: нет сценария «" .. name .. "» (auto_list)"
            else o.scenario = other.name end
          end
        elseif t == "give" then
          if not reg().owns("storage_take") then errs[#errs + 1] = path .. ": нет приложения «Склад»"
          else
            o.item = f_text(a.item, 80, path .. ".item", errs, true)
            if o.item and not o.item:match("^[%w_%.%-]+:[%w_%.%-/]+$") then errs[#errs + 1] = path .. ".item: ID предмета ns:id (storage_find)" end
            o.count = math.floor(f_num(a.count, 1, 4096, path .. ".count", errs, true, 1))
          end
        end
        r.acts[#r.acts + 1] = o
      end
    end
    if waits > WAIT_MAX then errs[#errs + 1] = "actions: ожидания в сумме не больше " .. WAIT_MAX .. " с" end
  end
  if r.when and r.when.type == "manual" and r.reply then warns[#warns + 1] = "reply нужен только для фразы" end
  if #errs > 0 then return nil, errs, warns end
  return r, nil, warns
end

-- ---------------------------------------------------------------- движок: запуск, шаги, действия (МОЖНО ждать)

local step   -- вперёд

local function cond_ok(ctx, r)
  for _, c in ipairs(r.cond or {}) do
    if c.type == "night" or c.type == "day" then
      local h = os.time()
      local night = h >= 18.5 or h < 5.5
      if (c.type == "night") ~= night then return false, c.type == "night" and "сейчас день" or "сейчас ночь" end
    elseif c.type == "online" or c.type == "offline" then
      local on = false
      for _, p in ipairs(ctx.online() or {}) do if tostring(p):lower() == tostring(c.player):lower() then on = true end end
      if (c.type == "online") ~= on then return false, c.player .. (on and " в игре" or " не в игре") end
    elseif c.type == "switch" then
      local P = panel()
      local sw = P and P.find(c.name)
      if not sw then return false, "нет переключателя «" .. tostring(c.name) .. "»" end
      local on = P.is_on(sw)
      if on == nil then return false, "«" .. sw.name .. "» не на связи" end
      if on ~= (c.state ~= "off") then return false, "«" .. sw.name .. "» " .. (on and "вкл" or "выкл") end
    end
  end
  return true
end

-- -> true | false, почему
local function start(ctx, r, why, o)
  o = o or {}
  local depth = o.depth or 0
  if not r.on and not o.manual then return false, "сценарий выключен" end
  if depth >= MAX_DEPTH then
    r.last_err = "цепочка сценариев длиннее " .. MAX_DEPTH .. " — остановлено"
    remember("«" .. r.name .. "»: " .. r.last_err)
    return false, r.last_err
  end
  local now = os.clock()
  for _, run in ipairs(E.runs) do
    if run.rule_id == r.id then return false, "уже выполняется" end
  end
  if E.last_start[r.id] and now - E.last_start[r.id] < (r.cooldown or GAP) then return false, "слишком часто" end
  local recent = {}
  for _, t in ipairs(E.starts) do if now - t < 60 then recent[#recent + 1] = t end end
  E.starts = recent
  if #recent >= RATE then
    if now - E.rate_warned > 60 then
      E.rate_warned = now
      ctx.say("Сценарии: больше " .. RATE .. " запусков в минуту — притормаживаю (проверьте, не зациклились ли).", "warn")
    end
    return false, "слишком много запусков подряд"
  end
  local ok, why_not = cond_ok(ctx, r)
  if not ok then
    r.last_skip = why_not
    return false, why_not
  end
  E.last_start[r.id] = now
  E.starts[#E.starts + 1] = now
  r.last, r.runs, r.last_why, r.last_skip, r.last_err = util.now(), (r.runs or 0) + 1, why, nil, nil
  E.runs[#E.runs + 1] = { rule_id = r.id, i = 1, wake = 0, depth = depth, who = o.who, errs = {} }
  remember("«" .. r.name .. "»: " .. tostring(why or "запуск"))
  A.every = 0.5
  ctx.save()
  ctx.later(step, ctx)
  return true
end

local function each_switch(a, fn)
  local P = panel()
  if not P then return nil, "нет приложения «Пульт»" end
  local list, why = P.resolve(a.name, a.group)
  if not list then return nil, why end
  local bad = {}
  for _, sw in ipairs(list) do
    local r, err = fn(P, sw)
    if not r then bad[#bad + 1] = "«" .. sw.name .. "» — " .. tostring(err) end
  end
  if #bad > 0 then return nil, table.concat(bad, "; ") end
  return true
end

local function do_action(ctx, r, a, run)
  local who = "сценарий «" .. r.name .. "»"
  local t = a.type
  if t == "switch" then
    return each_switch(a, function(P, sw) return P.set(sw, a.state, who, { ai = r.by_ai }) end)
  elseif t == "lock" or t == "unlock" then
    return each_switch(a, function(P, sw) return P.lock(sw, t == "lock", who, { ai = r.by_ai }) end)
  elseif t == "say" then
    ctx.say(a.text, "ai")
    local okt, tts = pcall(require, "tmai.tts")
    if okt and tts and tts.speak then pcall(tts.speak, a.text) end
    return true
  elseif t == "kpk" then
    ctx.kpk({ op = "notify", text = a.text, from = "Сценарий «" .. r.name .. "»" }, a.player)
    return true
  elseif t == "alert" then
    local key = "auto." .. r.id
    if not ctx.alert then return nil, "нет тревог" end
    if a.clear then ctx.alert.clear(key); return true end
    E.alert_depth[key] = run.depth
    ctx.alert.raise(key, a.text, { level = a.level or "warn", app = "auto", cooldown = 5 })
    return true
  elseif t == "event" then
    local msg = { name = a.name, data = a.data, from = "locman", scenario = r.name }
    if a.to then rednet.send(a.to, msg, scripts.EVENT_PROTO) else rednet.broadcast(msg, scripts.EVENT_PROTO) end
    return true
  elseif t == "program" then
    local code, j = scripts.find_job(a.program)
    if not code then return nil, "нет программы «" .. tostring(a.program) .. "»" end
    if a.op == "stop" then
      if j.state == "running" or j.state == "starting" then scripts.stop(code) end
      return true
    end
    if not j.ran then return nil, "программа не подтверждена игроком («да " .. code .. "»)" end
    return scripts.rerun(code)
  elseif t == "run" then
    local other = by_name(ctx, a.scenario)
    if not other then return nil, "нет сценария «" .. tostring(a.scenario) .. "»" end
    local ok, why = start(ctx, other, "из сценария «" .. r.name .. "»", { depth = run.depth + 1, who = run.who })
    if not ok then return nil, "«" .. other.name .. "» не запущен: " .. tostring(why) end
    return true
  elseif t == "enable" or t == "disable" then
    local other = by_name(ctx, a.scenario)
    if not other then return nil, "нет сценария «" .. tostring(a.scenario) .. "»" end
    other.on = t == "enable"
    ctx.save()
    return true
  elseif t == "give" then
    local res = reg().run_tool("storage_take", { item = a.item, count = a.count }, { player = run.who })
    if type(res) == "string" and (res:find("^отказ") or res:find("^ошибка")) then return nil, res end
    return true
  end
  return nil, "неизвестное действие"
end

step = function(ctx)
  if E.stepping then return end
  E.stepping = true
  local okall, errall = pcall(function()
    local i = 1
    while i <= #E.runs do
      local run = E.runs[i]
      local r = by_id(ctx, run.rule_id)
      if not r then table.remove(E.runs, i)
      elseif run.wake > os.clock() then i = i + 1
      else
        local finished = false
        while true do
          local a = r.acts[run.i]
          if not a then finished = true; break end
          run.i = run.i + 1
          if a.type == "wait" then run.wake = os.clock() + (tonumber(a.seconds) or 1); break end
          local ok, res, err = pcall(do_action, ctx, r, a, run)
          if not ok then res, err = nil, tostring(res) end
          if not res then
            local line = desc_act(a) .. ": " .. tostring(err or "не вышло")
            run.errs[#run.errs + 1] = line
            r.last_err = line
            remember("«" .. r.name .. "» — " .. line)
          end
        end
        if finished then
          table.remove(E.runs, i)
          if #run.errs > 0 then ctx.say("Сценарий «" .. r.name .. "»: " .. table.concat(run.errs, "; "), "warn") end
          ctx.save()
        else
          i = i + 1
        end
      end
    end
  end)
  E.stepping = false
  if not okall then util.log("W", "[auto] step: %s", tostring(errall)) end
end

-- ---------------------------------------------------------------- триггеры (опрос в tick; МОЖНО ждать)

local function rs_read(dev, side)
  if dev == "self" then
    if type(redstone) ~= "table" then return nil end
    local ok, v = pcall(redstone.getInput, side)
    if not ok then return nil end
    return v and true or false
  end
  if not (peripheral.hasType(dev, "redstone_relay") or peripheral.hasType(dev, "redstone_integrator")) then return nil end
  local ok, v = pcall(peripheral.call, dev, "getInput", side)
  if not ok then return nil end
  return v and true or false
end

-- Ключ и значение входа для триггера redstone (nil — не прочитать).
local function rs_value(w)
  if w.switch then
    local P = panel()
    local sw = P and P.find(w.switch)
    if not sw then return "sw:" .. w.switch, nil end
    if sw.kind == "lamp" then return "sw:" .. w.switch, rs_read(sw.dev, sw.side) end
    return "sw:" .. w.switch, P.is_on(sw)
  end
  return tostring(w.device) .. "|" .. tostring(w.side), rs_read(w.device, w.side)
end

local function poll_redstone(ctx)
  E.last_rs_poll = os.clock()
  local vals = {}
  local list = rules(ctx)
  for _, r in ipairs(list) do
    if r.on and r.when and r.when.type == "redstone" then
      local key, v = rs_value(r.when)
      if vals[key] == nil then vals[key] = { v = v } end
      local old = E.rs[key]
      if E.primed and v ~= nil and old ~= nil and old ~= v then
        local e = r.when.edge or "on"
        if e == "any" or (e == "on" and v) or (e == "off" and not v) then start(ctx, r, v and "сигнал включился" or "сигнал выключился") end
      end
    end
  end
  for k, x in pairs(vals) do if x.v ~= nil then E.rs[k] = x.v end end
end

-- Пересёк ли момент hour (часы Minecraft) промежуток (a, b] абсолютных часов.
local function crossed(a, b, hour)
  local n = math.floor((a - hour) / 24) + 1
  local tpoint = hour + 24 * n
  return tpoint > a and tpoint <= b
end

local function key_match(pat, key)
  if pat == "any" then return true end
  if pat:sub(-1) == "*" then return key:sub(1, #pat - 1) == pat:sub(1, -2) end
  return key == pat
end

local function poll(ctx)
  local list = rules(ctx)
  local any = { }
  for _, r in ipairs(list) do if r.on and r.when then any[r.when.type] = true end end
  -- сигнал
  if any.redstone then poll_redstone(ctx) end
  -- время Minecraft
  local abs = os.day() * 24 + os.time()
  if E.primed and E.time_abs and abs > E.time_abs and abs - E.time_abs < 48 and any.time then
    for _, r in ipairs(list) do
      if r.on and r.when.type == "time" and crossed(E.time_abs, abs, r.when.hour or 0) then start(ctx, r, "время " .. hours_text(r.when.hour or 0)) end
    end
  end
  E.time_abs = abs
  -- каждые N минут (реальных)
  local now = util.now()
  for _, r in ipairs(list) do
    if r.on and r.when.type == "every" then
      if not E.every_t[r.id] then E.every_t[r.id] = now
      elseif now - E.every_t[r.id] >= (r.when.minutes or 10) * 60 then
        E.every_t[r.id] = now
        start(ctx, r, "каждые " .. r.when.minutes .. " мин")
      end
    end
  end
  -- тревоги
  if ctx.alert and ctx.alert.list then
    local snap = {}
    for _, a in ipairs(ctx.alert.list()) do snap[a.key] = a.t or 0 end
    if E.alerts and any.alert then
      local events = {}
      for k, t in pairs(snap) do if E.alerts[k] ~= t then events[#events + 1] = { k, "raise" } end end
      for k in pairs(E.alerts) do if snap[k] == nil then events[#events + 1] = { k, "clear" } end end
      for _, ev in ipairs(events) do
        local depth = E.alert_depth[ev[1]] and (E.alert_depth[ev[1]] + 1) or 0
        for _, r in ipairs(list) do
          if r.on and r.when.type == "alert" and (r.when.edge or "raise") == ev[2] and key_match(r.when.key or "any", ev[1])
            and ev[1] ~= "auto." .. r.id then
            start(ctx, r, (ev[2] == "clear" and "снята тревога " or "тревога ") .. ev[1], { depth = depth })
          end
        end
      end
    end
    E.alerts = snap
  end
  -- игроки (детектор игроков ЛОЦМАНа; раз в 2 с)
  if any.player and os.clock() - E.players_t >= 2 then
    E.players_t = os.clock()
    local ranges = {}
    for _, r in ipairs(list) do if r.on and r.when.type == "player" then ranges[r.when.range or 16] = true end end
    local det = peripheral.find("player_detector") or peripheral.find("playerDetector")
    for range in pairs(ranges) do
      local names
      if range == 0 then names = ctx.online()
      elseif det then
        local ok, l = pcall(det.getPlayersInRange, range)
        names = ok and type(l) == "table" and l or nil
      end
      if names then
        local set = {}
        for _, n in ipairs(names) do if is_nick(n) then set[n] = true end end
        local old = E.players[range]
        if old and E.primed then
          local moves = {}
          for n in pairs(set) do if not old[n] then moves[#moves + 1] = { n, "arrive" } end end
          for n in pairs(old) do if not set[n] then moves[#moves + 1] = { n, "leave" } end end
          for _, mv in ipairs(moves) do
            for _, r in ipairs(list) do
              local w = r.when
              if r.on and w.type == "player" and (w.range or 16) == range and w.event == mv[2]
                and (not w.player or w.player:lower() == mv[1]:lower()) then
                start(ctx, r, mv[1] .. (mv[2] == "arrive" and " пришёл" or " ушёл"), { who = mv[1] })
              end
            end
          end
        end
        E.players[range] = set
      end
    end
  end
  E.primed = true
end

-- ---------------------------------------------------------------- жизненный цикл

local function retime(ctx)
  local list = rules(ctx)
  if #E.runs > 0 then A.every = 0.5; return end
  local need = 5
  for _, r in ipairs(list) do
    if r.on and r.when then
      local t = r.when.type
      if t == "redstone" or t == "player" or t == "time" then need = 1
      elseif t == "alert" or t == "every" then need = math.min(need, 2) end
    end
  end
  A.every = need
end

function A.init(ctx)
  local keep, maxid = {}, 0
  for _, r in ipairs(rules(ctx)) do
    if type(r) == "table" and type(r.name) == "string" and type(r.when) == "table" and type(r.acts) == "table" then
      r.id = tonumber(r.id)
      r.cond = type(r.cond) == "table" and r.cond or {}
      keep[#keep + 1] = r
      if r.id and r.id > maxid then maxid = r.id end
    end
  end
  for _, r in ipairs(keep) do if not r.id then maxid = maxid + 1; r.id = maxid end end
  ctx.data.rules = keep
  ctx.data.next_id = math.max(tonumber(ctx.data.next_id) or 1, maxid + 1)
  reset_engine()
  V = { mode = "list", sel = {}, top = {} }
  retime(ctx)
end

function A.tick(ctx)
  poll(ctx)
  step(ctx)
  retime(ctx)
end

function A.event(ctx, name, a, b, c)
  if name == "rednet_message" and c == scripts.EVENT_PROTO and type(b) == "table" and type(b.name) == "string" then
    local ev = b.name
    E.last_event = { name = ev, from = a, t = util.now() }
    for _, r in ipairs(rules(ctx)) do
      local w = r.when
      if r.on and w and w.type == "event" and norm(w.name) == norm(ev) and (not w.from or w.from == a) then
        ctx.later(start, ctx, r, "событие «" .. ev .. "» от #" .. tostring(a), { who = "#" .. tostring(a) })
      end
    end
  elseif name == "redstone" and os.clock() - E.last_rs_poll >= 0.3 then
    E.last_rs_poll = os.clock()
    ctx.later(function() poll_redstone(ctx); step(ctx) end)
  end
end

-- ---------------------------------------------------------------- фразы (зовёт app.lua ДО нейросети)

local function norm_phrase(s)
  s = u8.lower(tostring(s or ""))
  s = s:gsub("«", " "):gsub("»", " "):gsub("—", " "):gsub("–", " ")
  s = s:gsub("[%.,!%?;:\"'%(%)%-]", " ")
  s = s:gsub("%s+", " ")
  s = u8.trim(s)
  s = s:gsub("^лоцман%s+", "")
  return s
end

local function phrase_match(w, msg)
  local p = norm_phrase(w.text)
  if p == "" then return false end
  if w.exact ~= false then return msg == p end
  return (" " .. msg .. " "):find(" " .. p .. " ", 1, true) ~= nil
end

-- -> handled (true — ответили сами, в нейросеть не слать), ответ
function A.on_phrase(ctx, msg, player, via)
  local m = norm_phrase(msg)
  if m == "" then return false end
  -- «запусти / включи / выключи сценарий X»
  local verb, name = m:match("^(%S+) сценарий (.+)$")
  if verb and name then
    local r = by_name(ctx, name)
    if r and (verb == "запусти" or verb == "выполни") then
      local ok, why = start(ctx, r, "по просьбе " .. tostring(player or ""), { manual = true, who = player })
      return true, ok and ("Сценарий «" .. r.name .. "»: выполняю.") or ("Сценарий «" .. r.name .. "» не запущен: " .. tostring(why) .. ".")
    elseif r and (verb == "включи" or verb == "выключи") then
      r.on = verb == "включи"
      ctx.save()
      retime(ctx)
      return true, "Сценарий «" .. r.name .. "» " .. (r.on and "включён." or "выключен.")
    end
  end
  local answers, handled = {}, false
  for _, r in ipairs(rules(ctx)) do
    local w = r.when
    if r.on and w and w.type == "phrase" and phrase_match(w, m) and (not w.from or tostring(player or ""):lower() == w.from:lower()) then
      handled = true
      local ok, why = start(ctx, r, "фраза «" .. w.text .. "»" .. (player and (" от " .. tostring(player)) or ""), { who = player })
      if ok then answers[#answers + 1] = r.reply or ("Выполняю сценарий «" .. r.name .. "».")
      else answers[#answers + 1] = "Сценарий «" .. r.name .. "» не выполнен: " .. tostring(why) .. "." end
    end
  end
  if handled then return true, table.concat(answers, " ") end
  return false
end

-- «стоп» в чате (app.lua): прервать идущие сценарии (те, что ждут wait). -> сколько прервано
function A.stop_runs(ctx)
  local n = #E.runs
  for _, run in ipairs(E.runs) do
    local r = by_id(ctx, run.rule_id)
    if r then remember("«" .. r.name .. "»: прерван («стоп»)") end
  end
  E.runs = {}
  retime(ctx)
  return n
end

-- ---------------------------------------------------------------- действия вкладки, «Главная», инструменты, КПК

local function add_rule(ctx, src, by, by_ai, replace)
  local list = rules(ctx)
  local old = src and type(src.name) == "string" and replace and by_name(ctx, src.name)
  if old and norm(old.name) ~= norm(src.name) then old = nil end
  if not old and #list >= MAX_RULES then return nil, { "не больше " .. MAX_RULES .. " сценариев — удалите лишние" } end
  local r, errs, warns = validate(ctx, src, { by_ai = by_ai, except_id = old and old.id, replace = replace })
  if not r then return nil, errs, warns end
  if old then
    for k, v in pairs(r) do old[k] = v end
    old.by, old.by_ai, old.last_err, old.last_skip = by, by_ai, nil, nil
    r = old
  else
    r.id = math.max(tonumber(ctx.data.next_id) or 1, 1)
    ctx.data.next_id = r.id + 1
    r.by, r.by_ai, r.t, r.runs = by, by_ai, util.now(), 0
    list[#list + 1] = r
  end
  E.every_t[r.id] = nil
  ctx.save()
  retime(ctx)
  return r, nil, warns
end

local function remove_rule(ctx, r)
  local _, i = by_id(ctx, r.id)
  if not i then return false end
  table.remove(rules(ctx), i)
  for k = #E.runs, 1, -1 do if E.runs[k].rule_id == r.id then table.remove(E.runs, k) end end
  if ctx.alert then ctx.alert.clear("auto." .. r.id) end
  ctx.save()
  retime(ctx)
  return true
end

function A.action(ctx, act)
  local op = act.op
  if op == "add" then
    local r, errs = add_rule(ctx, act.rule, act.player or "экипаж", false, false)
    if not r then ctx.say("Сценарии: не сохранён — " .. table.concat(errs or {}, "; "), "warn")
    else ctx.say("Сценарий «" .. r.name .. "» сохранён: " .. desc_rule(r), "sys") end
    return
  end
  local r = by_id(ctx, act.id)
  if not r then return end
  if op == "run" then
    local ok, why = start(ctx, r, "вручную" .. (act.player and (" (" .. act.player .. ")") or ""), { manual = true, who = act.player })
    if not ok then ctx.say("Сценарий «" .. r.name .. "» не запущен: " .. tostring(why), "warn") end
  elseif op == "enable" then
    r.on = act.value and true or false
    if r.on then E.every_t[r.id] = nil end
    ctx.save()
    retime(ctx)
  elseif op == "remove" then
    remove_rule(ctx, r)
  end
end

function A.status(ctx)
  local list = rules(ctx)
  if #list == 0 then return nil end
  for _, run in ipairs(E.runs) do
    local r = by_id(ctx, run.rule_id)
    if r then return (text.fit("идёт: " .. r.name, 20, ".."):gsub("%s+$", "")) end
  end
  local on = 0
  for _, r in ipairs(list) do if r.on then on = on + 1 end end
  return "вкл " .. on .. " из " .. #list
end

local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end
local S = function(d) return { type = "string", description = d } end

local SCHEMA = {
  type = "object",
  description = "сценарий (данные, не код); формат и примеры — pack.auto",
  properties = {
    name = S("короткое имя по-русски, уникальное"),
    when = { type = "object", description = "триггер: {type: redstone|phrase|time|every|alert|player|event|manual, …поля типа}",
      properties = { type = { type = "string", enum = { "redstone", "phrase", "time", "every", "alert", "player", "event", "manual" } } },
      required = { "type" } },
    conditions = { type = "array", description = "необязательно: [{type: night|day|online|offline|switch, …}]",
      items = { type = "object", properties = { type = { type = "string", enum = { "night", "day", "online", "offline", "switch" } } }, required = { "type" } } },
    actions = { type = "array", description = "действия по порядку: [{type: switch|lock|unlock|say|kpk|alert|event|program|wait|run|enable|disable|give, …}]",
      items = { type = "object", properties = { type = { type = "string",
        enum = { "switch", "lock", "unlock", "say", "kpk", "alert", "event", "program", "wait", "run", "enable", "disable", "give" } } },
        required = { "type" } } },
    cooldown = { type = "integer", description = "не чаще раза в N секунд (по умолчанию 2)" },
    reply = S("для фразы: что ответить вместо «Выполняю сценарий…»"),
    enabled = { type = "boolean", description = "включён (по умолчанию true)" },
  },
  required = { "name", "when", "actions" },
}

function A.tools(ctx)
  local defs = {
    { name = "auto_add", description = "Сохранить сценарий «когда → [если] → что сделать» (ДАННЫЕ, не код; работает без нейросети). " ..
      "Перед первым — прочитай pack.auto (kb_read), если его нет в СПРАВКЕ; переключатели и группы — panel_list. " ..
      "Сначала кратко перескажи игроку, что будет делать сценарий. Ошибки — исправь и вызови снова. То же имя с replace=true — заменить.",
      parameters = obj({ scenario = SCHEMA, replace = { type = "boolean", description = "заменить сценарий с тем же именем" } }, { "scenario" }) },
  }
  if #rules(ctx) > 0 then
    defs[#defs + 1] = { name = "auto_list", description = "Сценарии: имя, включён, когда/если/что (словами и JSON), когда срабатывал, ошибки.",
      parameters = obj({}) }
    defs[#defs + 1] = { name = "auto_remove", description = "Удалить сценарий по имени.", parameters = obj({ name = S("имя сценария") }, { "name" }) }
    defs[#defs + 1] = { name = "auto_enable", description = "Включить или выключить сценарий (выключенный не срабатывает сам).",
      parameters = obj({ name = S("имя сценария"), enabled = { type = "boolean", description = "true — включить" } }, { "name", "enabled" }) }
    defs[#defs + 1] = { name = "auto_run", description = "Выполнить сценарий сейчас (проверит условия «если»).",
      parameters = obj({ name = S("имя сценария") }, { "name" }) }
  end
  return defs
end

local function info(r)
  local c = {}
  for _, x in ipairs(r.cond or {}) do c[#c + 1] = desc_cond(x) end
  local a = {}
  for _, x in ipairs(r.acts or {}) do a[#a + 1] = desc_act(x) end
  return { name = r.name, enabled = r.on and true or false, when = desc_when(r.when), conditions = #c > 0 and c or nil,
    actions = a, last = r.last and ago(r.last) or nil, runs = r.runs or 0, last_error = r.last_err, skipped = r.last_skip,
    by = r.by, json = export(r) }
end

function A.run_tool(ctx, name, args, tctx)
  local player = tctx and tctx.player
  if name == "auto_add" then
    local src = args.scenario
    if type(src) == "string" then src = json.decode(src) end
    local r, errs, warns = add_rule(ctx, src, player and (player .. " через ЛОЦМАНа") or "ЛОЦМАН", true, args.replace and true or false)
    if not r then
      return { ok = false, errors = errs, warnings = (warns and #warns > 0) and warns or nil,
        hint = "Исправь сценарий и вызови auto_add снова (формат — pack.auto)." }
    end
    return { ok = true, name = r.name, summary = desc_rule(r), warnings = (warns and #warns > 0) and warns or nil,
      say = "Сценарий «" .. r.name .. "» сохранён (вкладка «Сценарии»)." }
  elseif name == "auto_list" then
    local out = {}
    for _, r in ipairs(rules(ctx)) do out[#out + 1] = info(r) end
    return { scenarios = out, event_protocol = scripts.EVENT_PROTO }
  end
  local r = by_name(ctx, args.name)
  if not r then return "отказ: нет сценария «" .. tostring(args.name or "") .. "»; список — auto_list" end
  if name == "auto_remove" then
    remove_rule(ctx, r)
    return { removed = r.name }
  elseif name == "auto_enable" then
    r.on = args.enabled and true or false
    if r.on then E.every_t[r.id] = nil end
    ctx.save()
    retime(ctx)
    return { name = r.name, enabled = r.on }
  elseif name == "auto_run" then
    local ok, why = start(ctx, r, "по просьбе ЛОЦМАНу" .. (player and (" (" .. player .. ")") or ""), { manual = true, who = player })
    if not ok then return "не запущен: " .. tostring(why) end
    return { name = r.name, started = true, actions = info(r).actions }
  end
  return "нет такого инструмента"
end

A.radio = {
  list = function(ctx)
    local out = {}
    for _, r in ipairs(rules(ctx)) do out[#out + 1] = { name = r.name, enabled = r.on, when = desc_when(r.when), last = r.last and ago(r.last) } end
    return { scenarios = out }
  end,
  run = function(ctx, msg, sender, player)
    local r = by_name(ctx, msg.name)
    if not r then return nil, "нет такого сценария" end
    local ok, why = start(ctx, r, "с КПК " .. tostring(player or sender), { manual = true, who = player })
    if not ok then return nil, why end
    return { name = r.name, started = true }
  end,
}

-- ---------------------------------------------------------------- терминал: список, подробности, мастер (НЕ ждёт)

local function selectable(items, i) return items[i] ~= nil and items[i].sel end

local function fix_sel(items)
  local s = V.sel[V.mode] or 1
  if not selectable(items, s) then
    s = nil
    for i = 1, #items do if selectable(items, i) then s = i; break end end
    s = s or 1
  end
  V.sel[V.mode] = s
  return s
end

local function move_sel(items, dir, steps)
  local s = fix_sel(items)
  for _ = 1, steps or 1 do
    local i = s + dir
    while items[i] and not selectable(items, i) do i = i + dir end
    if selectable(items, i) then s = i else break end
  end
  V.sel[V.mode] = s
end

local function draw_row(ctx, t, x, yy, w, it, cur, rcol)
  local bg = cur and colors.gray or colors.black
  local prefix = it.sel and (cur and "> " or "  ") or "  "
  local rw = it.right and math.min(w - 3, math.max(text.len(it.right), rcol or 0)) or 0
  local rest = w - 2 - (rw > 0 and rw + 1 or 0)
  local mw = 0
  if it.mid and rest >= 18 then mw = math.min(text.len(it.mid), math.floor(rest * 0.5)) end
  local nw = rest - (mw > 0 and mw + 1 or 0)
  if nw < 1 then nw, mw, rw = math.max(1, w - 2), 0, 0 end
  ctx.put(t, x, yy, prefix .. text.fit(it.text, nw, ".."), it.fg or colors.white, bg)
  local xx = x + 2 + nw
  if mw > 0 then ctx.put(t, xx, yy, " " .. text.fit(it.mid, mw, ".."), colors.lightGray, bg); xx = xx + mw + 1 end
  if rw > 0 then ctx.put(t, xx, yy, " " .. text.fit(it.right, rw), it.rfg or colors.white, bg) end
end

local function running(r)
  for _, run in ipairs(E.runs) do if run.rule_id == r.id then return true end end
  return false
end

local function list_screen(ctx)
  local list = rules(ctx)
  local items, on = {}, 0
  for _, r in ipairs(list) do
    if r.on then on = on + 1 end
    local right, rfg
    if running(r) then right, rfg = "идёт", colors.orange
    elseif not r.on then right, rfg = "выкл", colors.gray
    elseif r.last_err then right, rfg = "ошибка", colors.red
    elseif r.last then right, rfg = ago(r.last, true), colors.lime
    else right, rfg = "вкл", colors.lime end
    items[#items + 1] = { text = r.name, mid = desc_when(r.when), right = right, rfg = rfg, sel = true, rule = r,
      fg = r.on and colors.white or colors.lightGray, desc = desc_rule(r) }
  end
  if #list == 0 then
    items[#items + 1] = { text = "Пока нет. Скажите ЛОЦМАНу: «когда …, сделай …»", fg = colors.gray }
    items[#items + 1] = { text = "или соберите сами: «+ сценарий».", fg = colors.gray }
  end
  if #list < MAX_RULES then
    items[#items + 1] = { text = "+ сценарий", fg = colors.cyan, sel = true, add = true,
      desc = "Мастер: одно «когда» и 1–3 действия (сложнее — словами ЛОЦМАНу)" }
  end
  return { title = "Сценарии", right = #list > 0 and ("вкл " .. on .. " из " .. #list) or nil, items = items }
end

-- ---------- мастер: шаги — функции (D — черновик) -> { title, items | input, submit }
local W = {}         -- шаги мастера
local MAX_WIZ_ACTS = 3

local function act_count(D) return #(D.actions or {}) end

local function wiz_back()
  local F = V.flow
  local h = table.remove(F.hist)
  if not h or not h.name then V.mode, V.flow, V.ed = "list", nil, nil; return end
  F.name, F.draft = h.name, h.draft
  V.sel.wiz, V.top.wiz = h.sel, nil
  -- шаг с вводом — заново (без истории: этот переход не запоминаем)
  local st = W[F.name](F.draft)
  V.err = nil
  if st and st.input then
    V.ed = input.new({ term = term, x = 1, y = 1, width = 51, prompt = st.input.prompt, max = st.input.max or 60,
      history = false, placeholder = st.input.placeholder, fg = colors.white, bg = colors.black, prompt_fg = colors.yellow,
      placeholder_fg = colors.gray })
    if st.input.value and st.input.value ~= "" then V.ed:set(st.input.value) end
  else
    V.ed = nil
  end
end

local function after_action()
  return function(D) return act_count(D) >= MAX_WIZ_ACTS and "name" or "act" end
end

W.when = function(D)
  local function pick(t, nxt) return function(D2) D2.when = { type = t }; return nxt end end
  return { title = "Новый сценарий · когда", items = {
    { text = "Кнопка или рычаг", mid = "сигнал на входе", sel = true, pick = pick("redstone", "rs_src"), desc = "Индикатор «Пульта» или сторона ретранслятора" },
    { text = "Фраза в чате или на КПК", mid = "«осада»", sel = true, pick = pick("phrase", "phrase") },
    { text = "Время суток", mid = "утро, вечер, полночь", sel = true, pick = pick("time", "time") },
    { text = "Каждые N минут", sel = true, pick = pick("every", "every") },
    { text = "Игрок пришёл", mid = "детектор игроков", sel = true, pick = function(D2) D2.when = { type = "player", event = "arrive" }; return "player" end },
    { text = "Игрок ушёл", sel = true, pick = function(D2) D2.when = { type = "player", event = "leave" }; return "player" end },
    { text = "Тревога", mid = "энергия, склад, программа", sel = true, pick = pick("alert", "alert") },
    { text = "Событие от программы", mid = "tmexec", sel = true, pick = pick("event", "event") },
    { text = "Только вручную", mid = "кнопкой или «запусти сценарий»", sel = true, pick = pick("manual", "act") },
  } }
end

W.rs_src = function(D)
  local items = {}
  local P = panel()
  for _, sw in ipairs(P and P.list() or {}) do
    items[#items + 1] = { text = "«" .. sw.name .. "»", mid = sw.kind == "lamp" and "индикатор" or "переключатель", sel = true,
      pick = function(D2) D2.when.switch = sw.name; D2.when.device, D2.when.side = nil, nil; return "rs_edge" end,
      desc = sw.kind == "lamp" and "Сигнал на входе индикатора" or "Срабатывает, когда этот переключатель переключили" }
  end
  items[#items + 1] = { text = "Сторона ретранслятора или компьютера…", fg = colors.cyan, sel = true, pick = function() return "rs_dev" end }
  return { title = "Когда · откуда сигнал", items = items }
end

W.rs_dev = function(D)
  local items = { { text = "Компьютер ИИ", mid = "его стороны", sel = true, pick = function(D2) D2.when.device = "self"; D2.when.switch = nil; return "rs_side" end } }
  for _, ty in ipairs({ "redstone_relay", "redstone_integrator" }) do
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.hasType(n, ty) then
        items[#items + 1] = { text = (ty == "redstone_relay" and "Реле " or "Интегратор ") .. (n:match("_(%d+)$") or n), mid = n, sel = true,
          pick = function(D2) D2.when.device = n; D2.when.switch = nil; return "rs_side" end }
      end
    end
  end
  return { title = "Когда · устройство", items = items }
end

W.rs_side = function(D)
  local items = {}
  for _, s in ipairs(SIDE_LIST) do
    items[#items + 1] = { text = SIDES[s] .. " (" .. s .. ")", sel = true, pick = function(D2) D2.when.side = s; return "rs_edge" end }
  end
  return { title = "Когда · сторона", items = items }
end

W.rs_edge = function(D)
  local function pick(e) return function(D2) D2.when.edge = e; return "act" end end
  return { title = "Когда · сигнал", items = {
    { text = "Включился", mid = "нажали кнопку", sel = true, pick = pick("on") },
    { text = "Выключился", sel = true, pick = pick("off") },
    { text = "Любое изменение", sel = true, pick = pick("any") },
  } }
end

W.phrase = function(D)
  return { title = "Когда · фраза", items = { { text = "Целиком, как скажут: «осада», «свет на базе».", fg = colors.lightGray },
    { text = "Сработает без нейросети, ответ — сразу.", fg = colors.lightGray } },
    input = { prompt = "Фраза: ", value = D.when.text, max = 60, placeholder = "осада" },
    submit = function(D2, txt)
      txt = u8.trim(txt or "")
      if text.len(txt) < 2 then return nil, "слишком коротко" end
      D2.when.text = txt
      return "act"
    end }
end

W.time = function(D)
  local items = {}
  for _, k in ipairs({ "morning", "noon", "evening", "night", "midnight" }) do
    items[#items + 1] = { text = TIME_RU[k], mid = hours_text(TIMES[k]), sel = true,
      pick = function(D2) D2.when.at = k; return "act" end }
  end
  items[1].text = "Утро"; items[2].text = "Полдень"; items[3].text = "Вечер"; items[4].text = "Ночь"; items[5].text = "Полночь"
  return { title = "Когда · время Minecraft", items = items }
end

W.every = function(D)
  return { title = "Когда · каждые N минут", items = { { text = "Минуты реального времени, от 1 до 1440.", fg = colors.lightGray } },
    input = { prompt = "Минут: ", value = tostring(D.when.minutes or 10), max = 4, placeholder = "10" },
    submit = function(D2, txt)
      local n = tonumber(u8.trim(txt or ""))
      if not n or n < 1 or n > 1440 then return nil, "нужно число от 1 до 1440" end
      D2.when.minutes = math.floor(n)
      return "act"
    end }
end

W.player = function(D, ctx)
  local items = { { text = "Любой игрок", sel = true, pick = function(D2) D2.when.player = nil; return "player_where" end } }
  for _, n in ipairs(V.online or {}) do
    items[#items + 1] = { text = n, sel = true, pick = function(D2) D2.when.player = n; return "player_where" end }
  end
  return { title = "Когда · кто", items = items }
end

W.player_where = function(D)
  local leave = D.when.event == "leave"
  return { title = "Когда · где", items = {
    { text = leave and "Ушёл от капсулы" or "Пришёл к капсуле", mid = "16 блоков от детектора", sel = true,
      pick = function(D2) D2.when.range = 16; return "act" end },
    { text = leave and "Вышел с сервера" or "Зашёл на сервер", sel = true, pick = function(D2) D2.when.range = 0; return "act" end },
  } }
end

W.alert = function(D)
  local items = {
    { text = "Любая тревога", sel = true, pick = function(D2) D2.when.key = "any"; return "act" end },
    { text = "Энергия базы ниже порога", mid = "base.energy", sel = true, pick = function(D2) D2.when.key = "base.energy"; return "act" end },
    { text = "Склад: мало предмета", mid = "storage.low.*", sel = true, pick = function(D2) D2.when.key = "storage.low.*"; return "act" end },
    { text = "Программа упала", mid = "programs.*", sel = true, pick = function(D2) D2.when.key = "programs.*"; return "act" end },
  }
  for _, a in ipairs(V.alerts or {}) do
    items[#items + 1] = { text = a.text, mid = a.key, sel = true, pick = function(D2) D2.when.key = a.key; return "act" end }
  end
  return { title = "Когда · какая тревога", items = items }
end

W.event = function(D)
  return { title = "Когда · событие от программы", items = { { text = "Имя события латиницей: lockdown, door_open.", fg = colors.lightGray },
    { text = "Программа шлёт его по rednet (tmai_event).", fg = colors.lightGray } },
    input = { prompt = "Событие: ", value = D.when.name, max = 32, placeholder = "lockdown" },
    submit = function(D2, txt)
      txt = u8.trim(txt or "")
      if not txt:match("^[%w_%.%-]+$") then return nil, "латиница, цифры, _ . -" end
      D2.when.name = txt
      return "act"
    end }
end

W.act = function(D)
  local n = act_count(D)
  local function pick(t, nxt) return function(D2) D2.cur = { type = t }; return nxt end end
  local items = {}
  if n > 0 then items[#items + 1] = { text = "Готово — дальше имя", fg = colors.cyan, sel = true, pick = function() return "name" end } end
  items[#items + 1] = { text = "Переключатель или группа", mid = "вкл, выкл, импульс", sel = true, pick = pick("switch", "target") }
  items[#items + 1] = { text = "Заблокировать", mid = "держит, нажатия не действуют", sel = true, pick = pick("lock", "target") }
  items[#items + 1] = { text = "Разблокировать", sel = true, pick = pick("unlock", "target") }
  items[#items + 1] = { text = "Сказать", mid = "лента и КПК", sel = true, pick = pick("say", "text") }
  items[#items + 1] = { text = "Тревога", sel = true, pick = pick("alert", "text") }
  items[#items + 1] = { text = "Событие программам", sel = true, pick = pick("event", "ev_name") }
  items[#items + 1] = { text = "Запустить программу", sel = true, pick = function(D2) D2.cur = { type = "program", op = "run" }; return "program" end }
  items[#items + 1] = { text = "Остановить программу", sel = true, pick = function(D2) D2.cur = { type = "program", op = "stop" }; return "program" end }
  items[#items + 1] = { text = "Ждать", mid = "секунды", sel = true, pick = pick("wait", "wait") }
  items[#items + 1] = { text = "Запустить другой сценарий", sel = true, pick = pick("run", "scenario") }
  return { title = "Что сделать · действие " .. (n + 1) .. " (до " .. MAX_WIZ_ACTS .. ")", items = items }
end

local function push_act(D, a)
  D.actions = D.actions or {}
  D.actions[#D.actions + 1] = a
  D.cur = nil
end

W.target = function(D)
  local items = {}
  local P = panel()
  local groups, seen = {}, {}
  for _, sw in ipairs(P and P.list() or {}) do
    for _, g in ipairs(type(sw.groups) == "table" and sw.groups or {}) do
      if not seen[g] then seen[g] = true; groups[#groups + 1] = g end
    end
  end
  table.sort(groups)
  local is_switch = D.cur.type == "switch"
  for _, g in ipairs(groups) do
    items[#items + 1] = { text = "все: " .. g, mid = "группа (" .. #P.members(g) .. ")", sel = true,
      pick = function(D2) D2.cur.group = g; if is_switch then return "state" end; push_act(D2, D2.cur); return after_action()(D2) end }
  end
  for _, sw in ipairs(P and P.list() or {}) do
    if sw.kind ~= "lamp" then
      items[#items + 1] = { text = "«" .. sw.name .. "»", mid = sw.kind == "pulse" and "импульс" or "вкл/выкл", sel = true,
        pick = function(D2) D2.cur.name = sw.name; D2.cur.pulse = sw.kind == "pulse"; if is_switch then return "state" end
          push_act(D2, D2.cur); return after_action()(D2) end }
    end
  end
  if #items == 0 then
    items[#items + 1] = { text = "На «Пульте» нет переключателей: сначала добавьте", fg = colors.gray }
    items[#items + 1] = { text = "выход ретранслятора на вкладке «Пульт».", fg = colors.gray }
  end
  return { title = "Что сделать · какой переключатель", items = items }
end

W.state = function(D)
  local function pick(st) return function(D2) D2.cur.state = st; D2.cur.pulse = nil; push_act(D2, D2.cur); return after_action()(D2) end end
  local items = {
    { text = "Включить", sel = true, pick = pick("on") }, { text = "Выключить", sel = true, pick = pick("off") },
    { text = "Переключить", sel = true, pick = pick("toggle") },
  }
  if D.cur.pulse then items[#items + 1] = { text = "Импульс", sel = true, pick = pick("pulse") } end
  return { title = "Что сделать · " .. (D.cur.group and ("все: " .. D.cur.group) or ("«" .. tostring(D.cur.name) .. "»")), items = items }
end

W.text = function(D)
  local alert = D.cur.type == "alert"
  return { title = "Что сделать · " .. (alert and "текст тревоги" or "что сказать"), items = { { text = alert and "Тревога: лента, КПК и звонок колонки." or "В ленту и на КПК (и вслух, если включена озвучка).", fg = colors.lightGray } },
    input = { prompt = "Текст: ", max = alert and 120 or 200, placeholder = alert and "Осада! Все в укрытие" or "Двери закрыты" },
    submit = function(D2, txt)
      txt = u8.trim(txt or "")
      if txt == "" then return nil, "пустой текст" end
      D2.cur.text = txt
      push_act(D2, D2.cur)
      return after_action()(D2)
    end }
end

W.ev_name = function(D)
  return { title = "Что сделать · событие программам", items = { { text = "Имя латиницей: lockdown. Программы ловят его по rednet.", fg = colors.lightGray } },
    input = { prompt = "Событие: ", max = 32, placeholder = "lockdown" },
    submit = function(D2, txt)
      txt = u8.trim(txt or "")
      if not txt:match("^[%w_%.%-]+$") then return nil, "латиница, цифры, _ . -" end
      D2.cur.name = txt
      push_act(D2, D2.cur)
      return after_action()(D2)
    end }
end

W.wait = function(D)
  return { title = "Что сделать · ждать", items = { { text = "Секунды, от 1 до 600.", fg = colors.lightGray } },
    input = { prompt = "Секунд: ", value = "5", max = 4, placeholder = "5" },
    submit = function(D2, txt)
      local n = tonumber(u8.trim(txt or ""))
      if not n or n < 1 or n > WAIT_MAX then return nil, "нужно число от 1 до " .. WAIT_MAX end
      D2.cur.seconds = n
      push_act(D2, D2.cur)
      return after_action()(D2)
    end }
end

W.program = function(D)
  local items = {}
  for _, j in ipairs(scripts.jobs()) do
    if D.cur.op == "stop" or j.ran then
      items[#items + 1] = { text = j.name, mid = "#" .. tostring(j.target) .. " · " .. j.job, sel = true,
        pick = function(D2) D2.cur.program = j.name; push_act(D2, D2.cur); return after_action()(D2) end }
    end
  end
  if #items == 0 then items[1] = { text = "Нет подходящих программ (запуск — только подтверждённых).", fg = colors.gray } end
  return { title = "Что сделать · программа", items = items }
end

W.scenario = function(D)
  local items = {}
  for _, r in ipairs(V.rules or {}) do
    items[#items + 1] = { text = r.name, mid = desc_when(r.when), sel = true,
      pick = function(D2) D2.cur.scenario = r.name; push_act(D2, D2.cur); return after_action()(D2) end }
  end
  if #items == 0 then items[1] = { text = "Других сценариев пока нет.", fg = colors.gray } end
  return { title = "Что сделать · какой сценарий", items = items }
end

W.name = function(D)
  local w = D.when or {}
  local suggest = w.type == "phrase" and w.text or (w.type == "time" and ("По времени " .. hours_text(TIMES[w.at] or 0)))
    or (w.type == "player" and (w.event == "leave" and "Уход" or "Приход")) or (w.type == "event" and w.name) or "Сценарий " .. ((#(V.rules or {})) + 1)
  return { title = "Имя сценария", items = { { text = "Коротко: «Осада», «Свет на ночь». По имени его найдёт ЛОЦМАН.", fg = colors.lightGray } },
    input = { prompt = "Имя: ", value = tostring(suggest), max = NAME_MAX, placeholder = "Осада" },
    submit = function(D2, txt)
      txt = u8.trim(txt or "")
      if txt == "" then return nil, "имя пустое" end
      for _, r in ipairs(V.rules or {}) do if norm(r.name) == norm(txt) then return nil, "такое имя уже есть" end end
      D2.name = txt
      return { op = "add", rule = { name = txt, when = D2.when, actions = D2.actions } }
    end }
end

-- ---------- подробности
local function body_lines(ctx, r, w)
  local out = {}
  local function add(s, fg) for _, l in ipairs(text.wrap(s, w)) do out[#out + 1] = { s = l, fg = fg or colors.white } end end
  add("Когда: " .. desc_when(r.when), colors.yellow)
  if #(r.cond or {}) > 0 then
    local c = {}
    for _, x in ipairs(r.cond) do c[#c + 1] = desc_cond(x) end
    add("Если: " .. table.concat(c, ", "), colors.yellow)
  end
  add("Что сделать:", colors.cyan)
  for i, a in ipairs(r.acts or {}) do add(i .. ". " .. desc_act(a)) end
  if r.reply then add("Ответ на фразу: «" .. r.reply .. "»", colors.lightGray) end
  if (r.cooldown or GAP) ~= GAP then add("Не чаще раза в " .. r.cooldown .. " с", colors.lightGray) end
  if r.last_err then add("Ошибка: " .. r.last_err, colors.red) end
  if r.last_skip then add("Пропущен: " .. r.last_skip, colors.orange) end
  add("Создал: " .. tostring(r.by or "?") .. (r.by_ai and " · переключатели «только вручную» не трогает" or ""), colors.lightGray)
  local mine = {}
  for _, l in ipairs(E.log) do if l:find("«" .. r.name .. "»", 1, true) then mine[#mine + 1] = l end end
  if #mine > 0 then
    add("Журнал:", colors.cyan)
    for i = math.max(1, #mine - 8), #mine do add(mine[i], colors.lightGray) end
  end
  return out
end

local function buttons(r)
  return { { "Запустить", "run" }, { r.on and "Выключить" or "Включить", "enable" },
    { V.arm and "Точно удалить?" or "Удалить", "remove" }, { "Назад", "back" } }
end

local function draw_detail(ctx, t, x, y, w, h, r)
  ctx.put(t, x, y, text.fit(r.name, w, ".."), colors.cyan, colors.black)
  local info_ = (r.on and "включён" or "выключен") .. " · " .. ago(r.last) .. (r.runs and r.runs > 0 and (" · запусков " .. r.runs) or "")
    .. (running(r) and " · идёт" or "")
  if h >= 2 then ctx.put(t, x, y + 1, text.fit(info_, w, ".."), r.on and colors.lime or colors.gray, colors.black) end
  local bs = buttons(r)
  if not V.btn or V.btn > #bs then V.btn = 1 end
  V.zones = {}
  if h >= 3 then
    local xx = x
    for i, b in ipairs(bs) do
      local label = "[" .. b[1] .. "]"
      local lw = text.len(label)
      if xx + lw - 1 > x + w - 1 then break end
      local on = i == V.btn
      ctx.put(t, xx, y + 2, label, on and colors.black or colors.white, on and (b[2] == "remove" and colors.red or colors.cyan) or colors.gray)
      V.zones[#V.zones + 1] = { x0 = xx, x1 = xx + lw - 1, y = y + 2, i = i }
      xx = xx + lw + 1
    end
  end
  local lines = body_lines(ctx, r, w)
  local rows = math.max(0, h - 4)
  V.rows = rows
  local top = math.max(1, math.min(V.dtop or 1, math.max(1, #lines - rows + 1)))
  V.dtop = top
  for i = 0, rows - 1 do
    local l = lines[top + i]
    if l then ctx.put(t, x, y + 3 + i, text.fit(l.s, w), l.fg, colors.black) end
  end
  if h >= 4 then
    local foot = V.arm and "Enter — удалить сценарий · ←→ — отмена"
      or (#lines > rows and ("строки %d–%d из %d · PgUp/PgDn"):format(top, math.min(#lines, top + rows - 1), #lines) or "")
    ctx.put(t, x, y + h - 1, text.fit(foot, w, ".."), V.arm and colors.orange or colors.gray, colors.black)
  end
end

local function current_screen(ctx)
  if V.mode == "wiz" and V.flow then
    local st = W[V.flow.name](V.flow.draft)
    st.items = st.items or {}
    return st
  end
  return list_screen(ctx)
end

local function draw_screen(ctx, t, x, y, w, h)
  local scr = current_screen(ctx)
  local items = scr.items
  local key = V.mode == "wiz" and "wiz" or "list"
  local saved = V.mode
  V.mode = key
  local sel = fix_sel(items)
  V.mode = saved
  local right = scr.right or ""
  local rl = (right ~= "" and text.len(right) + 1 < w - 4) and text.len(right) or 0
  ctx.put(t, x, y, text.fit(scr.title, w - (rl > 0 and rl + 1 or 0), ".."), colors.cyan, colors.black)
  if rl > 0 then ctx.put(t, x + w - rl - 1, y, " " .. right, colors.lightGray, colors.black) end
  local rows = math.max(0, h - 2)
  local top = V.top[key] or 1
  if sel < top then top = sel end
  if sel > top + rows - 1 then top = sel - rows + 1 end
  top = math.max(1, math.min(top, math.max(1, #items - rows + 1)))
  V.top[key] = top
  local rcol = 0
  for _, it in ipairs(items) do if it.rule and it.right then rcol = math.max(rcol, text.len(it.right)) end end
  for i = top, math.min(#items, top + rows - 1) do
    draw_row(ctx, t, x, y + 1 + i - top, w, items[i], i == sel and items[i].sel, items[i].rule and rcol or nil)
  end
  if h < 2 then return end
  local by = y + h - 1
  if scr.input and V.ed then
    if V.err then ctx.put(t, x, by - 1, text.fit(V.err, w), colors.red, colors.black) end
    V.ed.t = t
    V.ed:move(x, by, w)
    V.ed:draw()
    t.setCursorBlink(false)
  else
    local it = items[sel]
    local d = V.err or (it and it.sel and it.desc) or ""
    ctx.put(t, x, by, text.fit(d, w, ".."), V.err and colors.orange or colors.lightGray, colors.black)
  end
end

function A.draw(ctx, t, x, y, w, h, where_)
  V.rules = rules(ctx)
  V.online = ctx.online()
  V.alerts = ctx.alert and ctx.alert.list and ctx.alert.list() or {}
  if where_ == "monitor" then
    local yy = y
    for _, r in ipairs(rules(ctx)) do
      if yy > y + h - 1 then break end
      local st = running(r) and "идёт" or (r.on and "вкл" or "выкл")
      ctx.put(t, x, yy, text.fit(r.name, math.max(1, w - 5), "..") .. (w > 5 and (" " .. text.fit(st, 4)) or ""),
        r.on and colors.white or colors.gray, colors.black)
      yy = yy + 1
    end
    if yy == y then ctx.put(t, x, y, text.fit("Сценариев нет", w), colors.gray, colors.black) end
    return
  end
  V.area = { x = x, y = y, w = w, h = h }
  if V.mode == "detail" then
    local r = by_id(ctx, V.rid)
    if r then draw_detail(ctx, t, x, y, w, h, r); return end
    V.mode = "list"
  end
  draw_screen(ctx, t, x, y, w, h)
end

function A.cursor(ctx)
  local e = V.ed
  if V.mode ~= "wiz" or not e or not V.area then return nil end
  local cx = e.x + text.len(e.prompt) + e.pos - e.scroll
  if cx < V.area.x or cx > V.area.x + V.area.w - 1 then return nil end
  return cx, e.y
end

local function open_detail(r, arm)
  V.mode, V.rid, V.dtop, V.btn, V.arm = "detail", r.id, 1, 1, nil
  if arm then V.arm, V.btn = true, 3 end
end

local function press(ctx, i)
  local r = by_id(ctx, V.rid)
  if not r then V.mode = "list"; return nil end
  local b = buttons(r)[i]
  if not b then return nil end
  if b[2] == "back" then V.mode, V.arm = "list", nil; return nil end
  if b[2] == "remove" then
    if not V.arm then V.arm = true; return nil end
    V.mode, V.arm = "list", nil
    return { op = "remove", id = r.id }
  end
  V.arm = nil
  if b[2] == "enable" then return { op = "enable", id = r.id, value = not r.on } end
  return { op = "run", id = r.id }
end

local function choose(ctx, it)
  if V.mode == "list" then
    if it.add then
      V.mode = "wiz"
      V.flow = { name = "when", draft = {}, hist = {} }
      V.sel.wiz, V.top.wiz, V.err, V.ed = nil, nil, nil, nil
      return nil
    end
    if it.rule then open_detail(it.rule) end
    return nil
  end
  -- мастер
  if not it.pick then return nil end
  local F = V.flow
  local before = copy(F.draft)
  local nxt = it.pick(F.draft)
  if type(nxt) == "table" then V.mode, V.flow, V.ed = "list", nil, nil; return nxt end
  if type(nxt) == "string" then
    local cur = F.name
    F.hist[#F.hist + 1] = { name = cur, draft = before, sel = V.sel.wiz }
    F.name = nxt
    V.sel.wiz, V.top.wiz, V.err = nil, nil, nil
    local st = W[nxt](F.draft)
    if st.input then
      V.ed = input.new({ term = term, x = 1, y = 1, width = 51, prompt = st.input.prompt, max = st.input.max or 60,
        history = false, placeholder = st.input.placeholder, fg = colors.white, bg = colors.black, prompt_fg = colors.yellow,
        placeholder_fg = colors.gray })
      if st.input.value and st.input.value ~= "" then V.ed:set(st.input.value) end
    else
      V.ed = nil
    end
  end
  return nil
end

local function submit(ctx, scr, txt)
  local F = V.flow
  local before = copy(F.draft)
  local nxt, err = scr.submit(F.draft, txt)
  if not nxt then F.draft = before; V.err = err; return nil end
  if type(nxt) == "table" then V.mode, V.flow, V.ed = "list", nil, nil; return nxt end
  F.hist[#F.hist + 1] = { name = F.name, draft = before, sel = V.sel.wiz }
  F.name = nxt
  V.sel.wiz, V.top.wiz, V.err = nil, nil, nil
  local st = W[nxt](F.draft)
  if st.input then
    V.ed = input.new({ term = term, x = 1, y = 1, width = 51, prompt = st.input.prompt, max = st.input.max or 60,
      history = false, placeholder = st.input.placeholder, fg = colors.white, bg = colors.black, prompt_fg = colors.yellow,
      placeholder_fg = colors.gray })
    if st.input.value and st.input.value ~= "" then V.ed:set(st.input.value) end
  else
    V.ed = nil
  end
  return nil
end

function A.key(ctx, ev, a, b, c)
  V.rules = rules(ctx)
  V.online = ctx.online()
  V.alerts = ctx.alert and ctx.alert.list and ctx.alert.list() or {}
  if V.mode == "detail" then
    local rows = math.max(1, V.rows or 10)
    if ev == "key" then
      if a == keys.left or a == keys.right then
        V.btn = ((V.btn or 1) - 1 + (a == keys.left and -1 or 1)) % 4 + 1
        V.arm = nil
      elseif a == keys.enter then return true, press(ctx, V.btn or 1)
      elseif a == keys.backspace then V.mode, V.arm = "list", nil
      elseif a == keys.delete then
        if V.arm and V.btn == 3 then return true, press(ctx, 3) end
        V.btn, V.arm = 3, true
      elseif a == keys.up then V.dtop = (V.dtop or 1) - 1
      elseif a == keys.down then V.dtop = (V.dtop or 1) + 1
      elseif a == keys.pageUp then V.dtop = (V.dtop or 1) - (rows - 1)
      elseif a == keys.pageDown then V.dtop = (V.dtop or 1) + (rows - 1)
      else return false end
      return true
    elseif ev == "mouse_scroll" then
      V.dtop = (V.dtop or 1) + (a > 0 and 2 or -2)
      return true
    elseif ev == "mouse_click" then
      for _, z in ipairs(V.zones or {}) do
        if c == z.y and b >= z.x0 and b <= z.x1 then
          if z.i ~= V.btn then V.arm = nil end
          V.btn = z.i
          return true, press(ctx, z.i)
        end
      end
    end
    return false
  end
  local scr = current_screen(ctx)
  if V.mode == "wiz" and scr.input and V.ed then
    if ev == "key" and a == keys.up then wiz_back(); return true end
    local r, txt = V.ed:handle(ev, a, b, c)
    if r == "submit" then return true, submit(ctx, scr, txt) end
    if r ~= nil then V.err = nil end
    return r ~= nil
  end
  local key = V.mode == "wiz" and "wiz" or "list"
  local saved = V.mode
  local items = scr.items
  local rows = math.max(1, ((V.area and V.area.h) or 16) - 2)
  local function with(fn) V.mode = key; fn(); V.mode = saved end
  if ev == "key" then
    V.err = nil
    if a == keys.up then with(function() move_sel(items, -1) end)
    elseif a == keys.down then with(function() move_sel(items, 1) end)
    elseif a == keys.pageUp then with(function() move_sel(items, -1, rows - 1) end)
    elseif a == keys.pageDown then with(function() move_sel(items, 1, rows - 1) end)
    elseif a == keys.home then with(function() V.sel[key] = 1; fix_sel(items) end)
    elseif a == keys.enter then
      local it
      with(function() it = items[fix_sel(items)] end)
      if not it or not it.sel then return true end
      return true, choose(ctx, it)
    elseif (a == keys.backspace or a == keys.left) and V.mode == "wiz" then wiz_back()
    elseif a == keys.delete and V.mode == "list" then
      local it
      with(function() it = items[fix_sel(items)] end)
      if it and it.rule then open_detail(it.rule, true) end
    else return false end
    return true
  elseif ev == "mouse_scroll" then
    with(function() move_sel(items, a > 0 and 1 or -1) end)
    return true
  elseif ev == "mouse_click" and V.area then
    local ar = V.area
    local i = (V.top[key] or 1) + (c - ar.y - 1)
    if c > ar.y and c < ar.y + ar.h - 1 and b >= ar.x and b < ar.x + ar.w and selectable(items, i) then
      if V.sel[key] == i then return true, choose(ctx, items[i]) end
      V.sel[key] = i
      return true
    end
  end
  return false
end

function A.hint(ctx)
  if V.mode == "detail" then return "←→ Enter — кнопки · ↑↓ — листать · Bksp — назад" end
  if V.mode == "wiz" then
    if V.ed then return "Enter — дальше · ↑ — назад" end
    return "↑↓ — выбор · Enter — дальше · Backspace — назад"
  end
  return "Enter — подробнее · Delete — удалить"
end

-- для тестов и отладки
A._engine = function() return E end
A._validate = validate

return A
