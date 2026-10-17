-- tmai/apps/base.lua — приложение «База»: сводка энергии и МЭ-сети базы и тревоги. Работает без нейросети.
--
-- Устройства находит само — всё, что видит компьютер ИИ (вплотную и через проводные модемы):
--   FE-блоки без своей периферии — generic-периферия CC «energy_storage»: getEnergy / getEnergyCapacity;
--   Powah через Advanced Peripherals (energy_cell, ender_cell, furnator, magmator, thermo, solar_panel,
--     uraninite_reactor): getStoredEnergy / getMaxEnergy (FE);
--   Mekanism (энергокубы, порт индукционной матрицы, машины): getEnergy / getMaxEnergy в джоулях —
--     в FE через mekanismEnergyHelper.joulesToFE (нет его — 2,5 Дж = 1 FE);
--   датчик потока AP energy_detector: getTransferRate (FE/t).
-- Ядро ИИ (kubejs:ai_core) в сводку не входит: его заряд — в состоянии ЛОЦМАНа.
-- Накопители (ячейки, кубы, батареи, матрицы…) сразу видны и входят в сумму; машины и генераторы — в «Скрытых»
-- (их буфер — не запас базы), их можно показать. Устройство можно переименовать (Enter) и скрыть (Delete).
-- Тенденция — по изменению суммы за последние ~2 минуты (растёт/падает, на сколько хватит).
-- МЭ-сеть — через tmai.me (ME Bridge): заполненность, энергия, занятые процессоры.
-- Тревоги (tmai.alert, ключи base.*): энергия ниже N%, МЭ заполнена больше N%, МЭ пропала, устройство пропало.
-- Тревога поднимается один раз при входе в состояние и снимается (сообщение «… в норме»), когда прошло;
-- снятие — с запасом порога, чтобы не дёргаться на границе. Состояние тревог хранится в ctx.data.latch.
-- Инструменты нейросети: base_status, base_alerts, base_set_rule.

local text = require("tmai.text")
local util = require("tmai.util")
local json = require("tmai.json")

local M = { id = "base", title = "База", short = "База", order = 30, monitor = true, every = 5 }

local HYST = 3          -- запас порога при снятии тревоги, %
local LOST_AFTER = 2    -- столько опросов подряд устройства нет — пропало (защита от мигания сети)
local MAX_DEV = 64      -- больше устройств за один опрос не читаем
local MAX_LABEL = 24
local WINDOW = 120      -- окно тенденции, секунд

local RULES = {
  { id = "energy_low", title = "Энергия ниже", pct = 20, key = "base.energy",
    desc = "Тревога, когда запас энергии в накопителях базы ниже порога." },
  { id = "me_full", title = "МЭ заполнена больше", pct = 90, key = "base.me_full",
    desc = "Тревога, когда хранилище МЭ-сети заполнено больше порога." },
  { id = "me_lost", title = "МЭ-сеть пропала", key = "base.me",
    desc = "Тревога, если МЭ-сеть перестала отвечать (нет питания, канала или моста)." },
  { id = "device_lost", title = "Устройство пропало", key = "base.lost",
    desc = "Тревога, если накопитель или датчик исчез из сети компьютера ИИ." },
}
local RULE_BY = {}
for _, r in ipairs(RULES) do RULE_BY[r.id] = r end

-- Последний опрос (только память; rows/status берут отсюда и ничего не ждут).
local S = { scanned = false, devs = {}, order = {}, flows = {}, sum = nil, me = nil,
  samples = {}, sig = nil, miss = {}, me_miss = 0, lost = {}, t = nil }

-- ---------- названия и виды устройств ----------
local NAMES = {
  { "induction", "Индукционная матрица" }, { "energycube", "Энергокуб" }, { "energy_cube", "Энергокуб" },
  { "ender_cell", "Эндер-ячейка" }, { "energy_cell", "Энергоячейка" }, { "batter", "Батарея" },
  { "capacitor", "Конденсатор" }, { "accumulator", "Аккумулятор" }, { "flux", "Хранилище Flux" },
  { "furnator", "Углегенератор" }, { "magmator", "Магматор" }, { "thermo", "Термогенератор" },
  { "solar", "Солнечная панель" }, { "reactor", "Реактор" }, { "energy_detector", "Датчик потока" },
}
local STORE = { "cell", "cube", "batter", "capacitor", "accumulator", "induction", "matrix", "bank", "storage" }
local KIND_TEXT = { store = "накопитель", machine = "машина / генератор", flow = "датчик потока" }
local SIDES_RU = { top = "сверху", bottom = "снизу", left = "слева", right = "справа", front = "спереди", back = "сзади" }

local function lower(s) return (tostring(s or ""):gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)) end

local function is_store(t)
  local lt = lower(t)
  if lt == "energy_storage" then return false end
  for _, p in ipairs(STORE) do if lt:find(p, 1, true) then return true end end
  return false
end

local function default_label(name, t)
  local lt = lower(t)
  local base
  for _, p in ipairs(NAMES) do
    if lt:find(p[1], 1, true) then base = p[2]; break end
  end
  if not base then
    base = (tostring(t):match(":(.+)$") or tostring(t)):gsub("_", " ")
  end
  local n = tostring(name):match("_(%d+)$")
  if n then return base .. " " .. n end
  if SIDES_RU[name] then return base .. " (" .. SIDES_RU[name] .. ")" end
  return base
end

-- ---------- настройки в ctx.data ----------
local function rule(ctx, id)
  ctx.data.rules = type(ctx.data.rules) == "table" and ctx.data.rules or {}
  local r = ctx.data.rules[id]
  if type(r) ~= "table" then r = {}; ctx.data.rules[id] = r end
  if r.on == nil then r.on = true end
  if RULE_BY[id].pct and tonumber(r.pct) == nil then r.pct = RULE_BY[id].pct end
  return r
end

local function devs_cfg(ctx)
  if type(ctx.data.dev) ~= "table" then ctx.data.dev = {} end
  return ctx.data.dev
end

local function is_hidden(ctx, name, kind)
  local d = devs_cfg(ctx)[name]
  if d and d.hidden ~= nil then return d.hidden == true end
  return (kind or (d and d.kind)) == "machine"
end

local function label_of(ctx, name, t)
  local d = devs_cfg(ctx)[name]
  if d and type(d.label) == "string" and d.label ~= "" then return d.label end
  return default_label(name, t or (d and d.type) or name)
end

-- ---------- форматирование ----------
local UNITS = { { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }
local function fmt_num(v)
  v = tonumber(v) or 0
  local a = math.abs(v)
  for _, u in ipairs(UNITS) do
    if a >= u[1] then
      local x = v / u[1]
      if math.abs(x) >= 100 then return string.format("%d", math.floor(x + 0.5)) .. u[2] end
      return string.format("%.1f", x) .. u[2]
    end
  end
  if a >= 10 or a == 0 then return string.format("%d", math.floor(v + 0.5)) end
  return string.format("%.1f", v)
end

local function fmt_rate(r, unit)
  r = tonumber(r) or 0
  local s = fmt_num(math.abs(r))
  return (r > 0 and "+" or (r < 0 and "-" or "")) .. s .. " " .. (unit or "FE/t")
end

local function fmt_dur(sec)
  sec = math.max(0, tonumber(sec) or 0)
  if sec < 60 then return "меньше минуты" end
  local m = math.floor(sec / 60)
  if m < 60 then return m .. " мин" end
  local h = math.floor(m / 60)
  if h < 48 then return h .. " ч " .. (m % 60) .. " мин" end
  return math.floor(h / 24) .. " сут"
end

local function fmt_dur_short(sec)
  sec = math.max(0, tonumber(sec) or 0)
  if sec < 60 then return "<1м" end
  local m = math.floor(sec / 60)
  if m < 60 then return m .. "м" end
  local h = math.floor(m / 60)
  if h < 48 then return h .. "ч" .. (m % 60 > 0 and ((m % 60) .. "м") or "") end
  return math.floor(h / 24) .. "сут"
end

local function bar(pct, w)
  w = math.max(3, w)
  local inner = w - 2
  local f = math.floor(inner * math.max(0, math.min(100, pct or 0)) / 100 + 0.5)
  return "[" .. ("#"):rep(f) .. ("."):rep(inner - f) .. "]"
end

local function clean(s, max)
  s = tostring(s or ""):gsub("[%z\1-\31\127]", " ")
  s = s:gsub("^ +", ""):gsub(" +$", "")
  if max and text.len(s) > max then s = text.sub(s, 1, max) end
  return s
end

-- ---------- опрос периферии (только tick и инструменты: ждёт) ----------
local j2fe_k
local function j2fe()
  if j2fe_k then return j2fe_k end
  local k = 0.4                                     -- Mekanism по умолчанию: 2,5 Дж = 1 FE
  local api = type(mekanismEnergyHelper) == "table" and mekanismEnergyHelper or nil
  if api and api.joulesToFE then
    local ok, v = pcall(api.joulesToFE, 1000000)
    if ok and tonumber(v) and tonumber(v) > 0 then k = tonumber(v) / 1000000 end
  end
  j2fe_k = k
  return k
end

local function ptype(name)
  if peripheral.getType then
    local ok, t = pcall(peripheral.getType, name)
    if ok and type(t) == "string" then return t end
  end
  return (tostring(name):gsub("_%d+$", ""))
end

local mcache = {}
local function methods(name, t)
  local key = name .. "|" .. t
  if mcache[key] then return mcache[key] end
  local m, list = {}, nil
  if peripheral.getMethods then
    local ok, l = pcall(peripheral.getMethods, name)
    if ok and type(l) == "table" then list = l end
  end
  if list then
    for _, k in ipairs(list) do m[k] = true end
  else
    local w = peripheral.wrap(name)
    if type(w) == "table" then for k, v in pairs(w) do if type(v) == "function" then m[k] = true end end end
  end
  mcache[key] = m
  return m
end

local function pcall_num(name, meth)
  local ok, v = pcall(peripheral.call, name, meth)
  if ok then return tonumber(v) end
  return nil
end

local function read_dev(name, m)
  if m.getTransferRate then
    return { flow = pcall_num(name, "getTransferRate") }
  end
  local e, c, k = nil, nil, 1
  if m.getEnergy and m.getEnergyCapacity then
    e, c = pcall_num(name, "getEnergy"), pcall_num(name, "getEnergyCapacity")
  elseif m.getStoredEnergy and m.getMaxEnergy then
    e, c = pcall_num(name, "getStoredEnergy"), pcall_num(name, "getMaxEnergy")
  elseif m.getEnergy and m.getMaxEnergy then
    e, c, k = pcall_num(name, "getEnergy"), pcall_num(name, "getMaxEnergy"), j2fe()
  else
    return nil
  end
  if not e or not c then return { err = true } end
  return { e = math.max(0, e * k), cap = math.max(0, c * k) }
end

local function scan()
  local found, n = {}, 0
  for _, name in ipairs(peripheral.getNames()) do
    if n >= MAX_DEV then break end
    if not peripheral.hasType(name, "kubejs:ai_core") and not peripheral.hasType(name, "me_bridge") then
      local t = ptype(name)
      local m = methods(name, t)
      if m.getTransferRate or m.getEnergyCapacity or m.getMaxEnergy then
        n = n + 1
        local r = read_dev(name, m) or { err = true }
        r.name, r.ptype = name, t
        r.kind = m.getTransferRate and "flow" or (is_store(t) and "store" or "machine")
        found[name] = r
      end
    end
  end
  return found
end

-- Сумма по видимым накопителям; порты одной индукционной матрицы и эндер-ячейки одного канала
-- показывают общий запас — одинаковые показания считаем один раз.
local function summarize(ctx, add_sample)
  local names = {}
  for name in pairs(S.devs) do names[#names + 1] = name end
  table.sort(names)
  local e, cap, n, used, shared = 0, 0, 0, {}, {}
  local flows = {}
  for _, name in ipairs(names) do
    local r = S.devs[name]
    r.dup = nil
    if not is_hidden(ctx, name, r.kind) then
      if r.kind == "flow" then
        if r.flow then flows[#flows + 1] = r end
      elseif r.e then
        local lt = lower(r.ptype)
        local group = (lt:find("induction", 1, true) and "i") or (lt:find("ender_cell", 1, true) and "e") or nil
        if group then   -- та же ёмкость и почти тот же заряд (порты читаются в разные тики) — тот же запас
          for _, o in ipairs(shared) do
            if o.group == group and o.cap == r.cap and math.abs(o.e - r.e) <= math.max(1, r.cap * 0.01) then r.dup = o.name; break end
          end
          if not r.dup then shared[#shared + 1] = { group = group, cap = r.cap, e = r.e, name = name } end
        end
        if not r.dup then
          e, cap, n = e + r.e, cap + r.cap, n + 1
          used[#used + 1] = name
        end
      end
    end
  end
  S.order, S.flows = names, flows
  local sig = table.concat(used, ",")
  if sig ~= S.sig then S.samples, S.sig = {}, sig end
  local now = util.now()
  if add_sample and n > 0 then
    S.samples[#S.samples + 1] = { t = now, e = e }
    while #S.samples > 1 and (now - S.samples[1].t > 600 or #S.samples > 150) do table.remove(S.samples, 1) end
  end
  local sum = { n = n, e = e, cap = cap, pct = cap > 0 and math.max(0, math.min(100, math.floor(e * 100 / cap))) or 0 }
  -- тенденция: от самой старой точки в окне до последней
  local k = #S.samples
  if k >= 2 then
    local last, first = S.samples[k], S.samples[k]
    for i = k - 1, 1, -1 do
      first = S.samples[i]
      if last.t - first.t >= WINDOW then break end
    end
    local dt = last.t - first.t
    if dt >= 20 then
      local per_s = (last.e - first.e) / dt
      sum.rate = per_s / 20
      local eps = math.max(1, cap * 0.005 / 12000)        -- меньше 0,5% ёмкости за 10 минут — стоит на месте
      if sum.rate > eps then
        sum.sign, sum.trend = "+", "растёт"
        if cap > e then sum.eta, sum.eta_kind = (cap - e) / per_s, "full" end
      elseif sum.rate < -eps then
        sum.sign, sum.trend = "-", "падает"
        sum.eta, sum.eta_kind = e / -per_s, "empty"
      else
        sum.sign, sum.trend = "=", "стабильно"
      end
    end
  end
  S.sum = sum
end

local function me_poll(ctx)
  local me = ctx.me
  if type(me) ~= "table" or not me.attach then S.me = nil; return end
  local okA, present = pcall(me.attach)
  if not okA or not present then
    S.me = { present = false }
  else
    local okS, st = pcall(me.status)
    st = okS and type(st) == "table" and st or { connected = false, error = tostring(st) }
    local r = { present = true, connected = st.connected == true, error = st.error }
    if r.connected then
      r.used, r.max = tonumber(st.item_storage_used), tonumber(st.item_storage_max)
      if r.used and r.max and r.max > 0 then r.fill = math.max(0, math.min(100, math.floor(r.used * 100 / r.max))) end
      r.energy, r.usage = tonumber(st.energy_stored), tonumber(st.energy_usage)
      r.cpus = tonumber(st.crafting_cpus)
      local b = peripheral.find("me_bridge")
      if b then
        local ok1, cap = pcall(b.getEnergyCapacity)
        if ok1 and tonumber(cap) and tonumber(cap) > 0 then r.energy_max = tonumber(cap) end
        local ok2, cpus = pcall(b.getCraftingCPUs)
        if ok2 and type(cpus) == "table" then
          local busy = 0
          for _, c in ipairs(cpus) do if type(c) == "table" and c.isBusy then busy = busy + 1 end end
          r.cpus, r.busy = #cpus, busy
        end
      end
    end
    S.me = r
  end
  if S.me.connected then
    S.me_miss = 0
    if not ctx.data.me_seen then ctx.data.me_seen = true; ctx.save() end
  else
    S.me_miss = S.me_miss + 1
  end
end

-- ---------- тревоги ----------
local function base_alerts(ctx)
  local out = {}
  if not (ctx.alert and ctx.alert.list) then return out end
  for _, a in ipairs(ctx.alert.list()) do
    if type(a.key) == "string" and a.key:sub(1, 5) == "base." then out[#out + 1] = a end
  end
  return out
end

-- on: true — должна висеть (с этим текстом), false — снять (ok_text — сообщение «в норме»), nil — не трогать.
local function set_alert(ctx, key, on, msg, level, ok_text)
  if on == nil then return false end
  ctx.data.latch = type(ctx.data.latch) == "table" and ctx.data.latch or {}
  local L = ctx.data.latch
  if on then
    if L[key] == msg then return false end
    L[key] = msg
    if ctx.alert then ctx.alert.raise(key, msg, { level = level or "warn", app = "base" }) end
    return true
  end
  if not L[key] then return false end
  L[key] = nil
  if ctx.alert then ctx.alert.clear(key, ok_text) end
  return true
end

local function lost_labels(ctx)
  local out = {}
  for name in pairs(S.lost) do
    local d = devs_cfg(ctx)[name]
    if d and not is_hidden(ctx, name, d.kind) then out[#out + 1] = label_of(ctx, name) end
  end
  table.sort(out)
  return out
end

local function evaluate(ctx)
  if not S.scanned then return end
  local changed = false
  local function apply(...) if set_alert(ctx, ...) then changed = true end end
  -- энергия
  local r = rule(ctx, "energy_low")
  local sum = S.sum
  if not r.on or not sum or sum.n == 0 then
    apply("base.energy", false)
  elseif sum.pct < r.pct then
    apply("base.energy", true, "База: энергия ниже " .. r.pct .. "%", sum.pct < r.pct / 2 and "crit" or "warn")
  elseif sum.pct >= math.min(100, r.pct + HYST) then
    apply("base.energy", false, nil, nil, "База: энергия в норме (" .. sum.pct .. "%)")
  end
  -- МЭ заполнена
  local me = S.me
  r = rule(ctx, "me_full")
  if not r.on or not me or not me.present then
    apply("base.me_full", false)
  elseif me.connected and me.fill then
    if me.fill > r.pct then
      apply("base.me_full", true, "База: МЭ-сеть заполнена больше " .. r.pct .. "%", me.fill >= 99 and "crit" or "warn")
    elseif me.fill <= math.max(0, r.pct - HYST) then
      apply("base.me_full", false, nil, nil, "База: в МЭ-сети снова есть место (" .. me.fill .. "%)")
    end
  end
  -- МЭ пропала
  r = rule(ctx, "me_lost")
  if not r.on or not ctx.data.me_seen then
    apply("base.me", false)
  elseif me and me.connected then
    apply("base.me", false, nil, nil, "База: МЭ-сеть снова на связи")
  elseif S.me_miss >= LOST_AFTER then
    apply("base.me", true, "База: МЭ-сеть пропала из сети", "crit")
  end
  -- устройства пропали
  r = rule(ctx, "device_lost")
  local lost = lost_labels(ctx)
  if not r.on then
    apply("base.lost", false)
  elseif #lost == 0 then
    apply("base.lost", false, nil, nil, "База: все устройства снова в сети")
  else
    local shown = {}
    for i = 1, math.min(3, #lost) do shown[i] = lost[i] end
    local msg = "База: пропало из сети — " .. table.concat(shown, ", ") .. (#lost > 3 and (" (+" .. (#lost - 3) .. ")") or "")
    apply("base.lost", true, msg, "warn")
  end
  if changed then ctx.save() end
end

-- ---------- жизненный цикл ----------
function M.init(ctx)
  devs_cfg(ctx)
  for _, r in ipairs(RULES) do rule(ctx, r.id) end
end

function M.tick(ctx)
  local found = scan()
  local cfg, changed = devs_cfg(ctx), false
  for name, r in pairs(found) do
    local d = cfg[name]
    if not d then
      cfg[name] = { kind = r.kind, type = r.ptype }; changed = true
    elseif d.kind ~= r.kind or d.type ~= r.ptype then
      d.kind, d.type = r.kind, r.ptype; changed = true
    end
    S.miss[name] = nil
  end
  S.lost = {}
  for name in pairs(cfg) do
    if not found[name] then
      S.miss[name] = (S.miss[name] or 0) + 1
      if S.miss[name] >= LOST_AFTER then S.lost[name] = true end
    end
  end
  S.devs = found
  summarize(ctx, true)
  me_poll(ctx)
  S.scanned, S.t = true, util.now()
  if changed then ctx.save() end
  evaluate(ctx)
end

-- ---------- действия экрана ----------
function M.action(ctx, act)
  local op = act.op
  local cfg = devs_cfg(ctx)
  local name = type(act.name) == "string" and act.name or nil
  if op == "rename" and name then
    cfg[name] = cfg[name] or {}
    local v = clean(act.value, MAX_LABEL)
    cfg[name].label = v ~= "" and v or nil
  elseif op == "hide" and name then
    local d = cfg[name] or {}
    cfg[name] = d
    local kind = d.kind or (S.devs[name] and S.devs[name].kind)
    d.hidden = not is_hidden(ctx, name, kind)
  elseif op == "forget" and name then
    cfg[name] = nil
    S.miss[name], S.lost[name] = nil, nil
  elseif op == "rule_toggle" and RULE_BY[act.rule] then
    local r = rule(ctx, act.rule)
    r.on = not r.on
    if not r.on then set_alert(ctx, RULE_BY[act.rule].key, false) end
  elseif op == "rule_pct" and RULE_BY[act.rule] and RULE_BY[act.rule].pct then
    local n = tonumber((tostring(act.value or ""):gsub("[%%%s]", "")))
    if n and n >= 1 and n <= 99 then
      local r = rule(ctx, act.rule)
      r.pct, r.on = math.floor(n), true
      set_alert(ctx, RULE_BY[act.rule].key, false)   -- текст тревоги с новым порогом поднимется заново, если нужно
    end
  elseif op == "me_forget" then
    ctx.data.me_seen = nil
    set_alert(ctx, "base.me", false)
  else
    return
  end
  ctx.save()
  if S.scanned then summarize(ctx, false) end
  evaluate(ctx)
end

-- ---------- экраны (ничего не ждут) ----------
local function pct_fg(ctx, pct)
  local r = rule(ctx, "energy_low")
  if pct < r.pct then return colors.red end
  if pct < 50 then return colors.yellow end
  return colors.lime
end

local function trend_line(sum)
  if not sum.trend then return "тенденция: считаю…" end
  if sum.sign == "=" then return "стабильно (" .. fmt_rate(sum.rate) .. ")" end
  local s = sum.trend .. ", " .. fmt_rate(sum.rate)
  if sum.eta_kind == "full" then s = s .. ", полный через ~" .. fmt_dur(sum.eta)
  elseif sum.eta_kind == "empty" then s = s .. ", хватит на ~" .. fmt_dur(sum.eta) end
  return s
end

local function dev_value(r)
  if not r then return "нет в сети" end
  if r.err then return "нет ответа" end
  if r.kind == "flow" then return fmt_rate(r.flow or 0) end
  local pct = r.cap > 0 and math.floor(r.e * 100 / r.cap) or 0
  return fmt_num(r.e) .. " FE " .. pct .. "%"
end

local function dev_row(ctx, name, hidden)
  local r = S.devs[name]
  local d = devs_cfg(ctx)[name] or {}
  local kind = (r and r.kind) or d.kind or "machine"
  local lbl = label_of(ctx, name, r and r.ptype)
  local val = dev_value(r)
  local fg = hidden and colors.gray or colors.white
  if r and r.dup then
    val = "= " .. label_of(ctx, r.dup, S.devs[r.dup] and S.devs[r.dup].ptype)
    fg = colors.lightGray
  end
  if not r then fg = colors.orange end
  return {
    text = lbl, value = val, fg = fg,
    prompt = { label = "Имя", op = "rename", name = name, value = (type(d.label) == "string" and d.label) or "", max = MAX_LABEL },
    del = { op = "hide", name = name },
    desc = name .. " — " .. (KIND_TEXT[kind] or kind) .. (r and r.dup and ", тот же запас, что у соседа" or ""),
    hint = "Enter — переименовать · Delete — " .. (hidden and "показать" or "скрыть"),
  }
end

local function rules_rows(ctx, out)
  out[#out + 1] = { text = "Тревоги", header = true }
  for _, R in ipairs(RULES) do
    local r = rule(ctx, R.id)
    if R.pct then
      out[#out + 1] = { text = R.title, value = r.on and (r.pct .. "%") or "выкл", fg = r.on and colors.white or colors.gray,
        prompt = { label = "Порог, % (1–99)", op = "rule_pct", rule = R.id, value = tostring(r.pct), max = 3 },
        del = { op = "rule_toggle", rule = R.id }, desc = R.desc, hint = "Enter — порог · Delete — вкл/выкл" }
    else
      out[#out + 1] = { text = R.title, value = r.on and "вкл" or "выкл", fg = r.on and colors.white or colors.gray,
        action = { op = "rule_toggle", rule = R.id, label = "вкл/выкл" }, desc = R.desc, hint = "Enter — вкл/выкл" }
    end
  end
  for _, a in ipairs(base_alerts(ctx)) do
    out[#out + 1] = { text = "! " .. a.text, fg = a.level == "crit" and colors.red or colors.orange }
  end
end

local function compact_rows(ctx, w)
  local out = {}
  if not S.scanned then return { { text = "База: опрос…", fg = colors.gray } } end
  local sum = S.sum
  if sum and sum.n > 0 then
    out[#out + 1] = { text = "Энергия " .. sum.pct .. "%" .. (sum.sign and (" " .. sum.sign) or ""), header = true }
    out[#out + 1] = { text = bar(sum.pct, w - 2), fg = pct_fg(ctx, sum.pct) }
    if sum.rate then out[#out + 1] = { text = fmt_rate(sum.rate) } end
    if sum.eta_kind == "empty" then out[#out + 1] = { text = "хватит ~" .. fmt_dur_short(sum.eta), fg = colors.yellow }
    elseif sum.eta_kind == "full" then out[#out + 1] = { text = "полный ~" .. fmt_dur_short(sum.eta) } end
  else
    out[#out + 1] = { text = "Энергия", header = true }
    out[#out + 1] = { text = "нет накопителей", fg = colors.gray }
  end
  local me = S.me
  if me and me.present then
    if me.connected then
      local s = "МЭ " .. (me.fill and (me.fill .. "%") or "?")
      if me.cpus and me.cpus > 0 then s = s .. " ЦП " .. (me.busy or 0) .. "/" .. me.cpus end
      out[#out + 1] = { text = s, header = true }
    else
      out[#out + 1] = { text = "МЭ: нет связи", fg = colors.red }
    end
  end
  local al = base_alerts(ctx)
  if #al > 0 then
    out[#out + 1] = { text = "Тревог: " .. #al, fg = colors.red }
    out[#out + 1] = { text = (al[1].text:gsub("^База: ", "")), fg = colors.orange }
  end
  return out
end

function M.rows(ctx, w)
  w = tonumber(w) or 51
  if w < 30 then return compact_rows(ctx, w) end
  local out = {}
  out[#out + 1] = { text = "Энергия базы", header = true }
  local sum = S.sum
  if not S.scanned then
    out[#out + 1] = { text = "ищу устройства…", fg = colors.gray }
  elseif not sum or sum.n == 0 then
    out[#out + 1] = { text = "накопителей в сети нет", fg = colors.gray }
    out[#out + 1] = { text = "подключите их к компьютеру ИИ проводным модемом", fg = colors.gray }
  else
    out[#out + 1] = { text = "Запас (" .. sum.n .. ")", value = fmt_num(sum.e) .. " / " .. fmt_num(sum.cap) .. " FE " .. sum.pct .. "%",
      fg = pct_fg(ctx, sum.pct) }
    out[#out + 1] = { text = bar(sum.pct, w - 2), fg = pct_fg(ctx, sum.pct) }
    out[#out + 1] = { text = trend_line(sum), fg = sum.sign == "-" and colors.yellow or colors.white }
  end
  -- видимые устройства
  local cfg = devs_cfg(ctx)
  local shown, hidden, gone = {}, {}, {}
  local all = {}
  for name in pairs(cfg) do all[#all + 1] = name end
  table.sort(all, function(a, b) return label_of(ctx, a) < label_of(ctx, b) end)
  for _, name in ipairs(all) do
    local r = S.devs[name]
    local kind = (r and r.kind) or cfg[name].kind
    if is_hidden(ctx, name, kind) then hidden[#hidden + 1] = name
    elseif not r then gone[#gone + 1] = name
    else shown[#shown + 1] = name end
  end
  local stores, flows = {}, {}
  for _, name in ipairs(shown) do
    if S.devs[name].kind == "flow" then flows[#flows + 1] = name else stores[#stores + 1] = name end
  end
  if #stores > 0 then
    out[#out + 1] = { text = "Накопители", header = true }
    for _, name in ipairs(stores) do out[#out + 1] = dev_row(ctx, name, false) end
  end
  if #flows > 0 then
    out[#out + 1] = { text = "Потоки энергии", header = true }
    for _, name in ipairs(flows) do out[#out + 1] = dev_row(ctx, name, false) end
  end
  -- МЭ-сеть
  out[#out + 1] = { text = "МЭ-сеть", header = true }
  local me = S.me
  if not me or not me.present then
    if ctx.data.me_seen then
      out[#out + 1] = { text = "МЭ-мост не найден", fg = colors.orange, del = { op = "me_forget" },
        desc = "Мост раньше был в сети. Delete — больше не следить за МЭ-сетью.", hint = "Delete — не следить" }
    else
      out[#out + 1] = { text = "нет МЭ-моста (ME Bridge) в сети", fg = colors.gray }
    end
  elseif not me.connected then
    out[#out + 1] = { text = "не отвечает", value = me.error and text.sub(tostring(me.error), 1, 25) or nil, fg = colors.red,
      del = { op = "me_forget" }, desc = tostring(me.error or "нет питания или канала"), hint = "Delete — не следить за МЭ-сетью" }
  else
    out[#out + 1] = { text = "Хранилище", value = (me.fill and (me.fill .. "% ") or "") .. fmt_num(me.used) .. " / " .. fmt_num(me.max),
      fg = me.fill and me.fill > rule(ctx, "me_full").pct and colors.red or colors.white }
    local ev = me.energy_max and (math.floor((me.energy or 0) * 100 / me.energy_max) .. "%") or (fmt_num(me.energy) .. " AE")
    out[#out + 1] = { text = "Энергия", value = ev .. ", " .. fmt_rate(-(me.usage or 0), "AE/t") }
    if me.cpus then
      out[#out + 1] = { text = "Процессоры крафта", value = me.busy and ((me.busy) .. " из " .. me.cpus .. " заняты") or tostring(me.cpus) }
    end
  end
  rules_rows(ctx, out)
  if #gone > 0 then
    out[#out + 1] = { text = "Нет в сети", header = true }
    for _, name in ipairs(gone) do
      local d = cfg[name]
      out[#out + 1] = { text = label_of(ctx, name), value = "пропало", fg = colors.orange, row = { kind = "lost" },
        del = { op = "forget", name = name }, desc = name .. " — проверьте модем и кабель (ПКМ по модему — в сеть)",
        hint = "Delete — забыть устройство" }
      if d.kind == "flow" then out[#out].value = "датчик пропал" end
    end
  end
  if #hidden > 0 then
    out[#out + 1] = { text = "Скрытые (не в сумме)", header = true }
    for _, name in ipairs(hidden) do
      local row = dev_row(ctx, name, true)
      if not S.devs[name] then row.del = { op = "forget", name = name }; row.hint = "Enter — переименовать · Delete — забыть" end
      out[#out + 1] = row
    end
  end
  return out
end

function M.status(ctx)
  local sum = S.sum
  if sum and sum.n > 0 then
    return "энергия " .. sum.pct .. "%" .. ((sum.sign == "+" or sum.sign == "-") and (" " .. sum.sign) or "")
  end
  local me = S.me
  if me and me.connected and me.fill then return "МЭ " .. me.fill .. "%" end
  if not S.scanned then return nil end
  return "нет устройств"
end

-- ---------- нейросеть ----------
local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end

function M.tools(ctx, tctx)
  return {
    { name = "base_status", description = "Сводка базы без догадок: запас энергии в накопителях (FE, %, растёт/падает, на сколько хватит), потоки энергии, МЭ-сеть (заполненность, энергия, процессоры), устройства и активные тревоги.",
      parameters = obj({}) },
    { name = "base_alerts", description = "Правила тревог базы (пороги, вкл/выкл) и активные тревоги.", parameters = obj({}) },
    { name = "base_set_rule", description = "Изменить правило тревоги базы по просьбе игрока. rule: energy_low (энергия ниже percent%), me_full (МЭ заполнена больше percent%), me_lost (МЭ-сеть пропала), device_lost (устройство пропало).",
      parameters = obj({
        rule = { type = "string", enum = { "energy_low", "me_full", "me_lost", "device_lost" }, description = "какое правило" },
        percent = { type = "integer", description = "порог 1..99 (только energy_low и me_full)" },
        on = { type = "boolean", description = "включить (true) или выключить (false)" },
      }, { "rule" }) },
  }
end

local function round1(v) return math.floor((tonumber(v) or 0) * 10 + 0.5) / 10 end

local function alerts_table(ctx)
  local active = {}
  for _, a in ipairs(base_alerts(ctx)) do active[#active + 1] = { text = a.text, level = a.level } end
  local rules = {}
  for _, R in ipairs(RULES) do
    local r = rule(ctx, R.id)
    rules[#rules + 1] = { rule = R.id, title = R.title, on = r.on, percent = R.pct and r.pct or nil }
  end
  return { rules = rules, active = #active > 0 and active or "тревог нет" }
end

local function status_table(ctx)
  local out = {}
  local sum = S.sum
  if sum and sum.n > 0 then
    out.energy = { stored_fe = math.floor(sum.e), capacity_fe = math.floor(sum.cap), percent = sum.pct, storages = sum.n,
      trend = sum.trend or "пока не ясно (нужно ~20 секунд наблюдения)", rate_fe_per_tick = sum.rate and round1(sum.rate) or nil }
    if sum.eta_kind == "empty" then out.energy.runs_out_in = fmt_dur(sum.eta)
    elseif sum.eta_kind == "full" then out.energy.full_in = fmt_dur(sum.eta) end
  else
    out.energy = "накопителей энергии в сети компьютера ИИ нет (подключить проводным модемом); ядро ИИ сюда не входит — см. power_status"
  end
  local devices, n = {}, 0
  for _, name in ipairs(S.order) do
    local r = S.devs[name]
    if n < 30 and not is_hidden(ctx, name, r.kind) then
      n = n + 1
      local d = { name = label_of(ctx, name, r.ptype), peripheral = name, kind = KIND_TEXT[r.kind] }
      if r.err then d.state = "не отвечает"
      elseif r.kind == "flow" then d.flow_fe_per_tick = round1(r.flow or 0)
      else
        d.stored_fe, d.capacity_fe = math.floor(r.e), math.floor(r.cap)
        d.percent = r.cap > 0 and math.floor(r.e * 100 / r.cap) or 0
        if r.dup then d.same_as = label_of(ctx, r.dup) end
      end
      devices[#devices + 1] = d
    end
  end
  out.devices = #devices > 0 and devices or "нет"
  local lost = lost_labels(ctx)
  if #lost > 0 then out.missing = lost end
  local me = S.me
  if not me or not me.present then out.me = "МЭ-моста в сети нет"
  elseif not me.connected then out.me = { online = false, error = me.error }
  else
    out.me = { online = true, storage_percent = me.fill, used_bytes = me.used, total_bytes = me.max,
      energy_ae = me.energy and math.floor(me.energy) or nil, energy_percent = me.energy_max and math.floor((me.energy or 0) * 100 / me.energy_max) or nil,
      usage_ae_per_tick = me.usage and round1(me.usage) or nil, crafting_cpus = me.cpus, busy_cpus = me.busy }
  end
  out.alerts = alerts_table(ctx).active
  out.updated_seconds_ago = S.t and math.floor(util.now() - S.t) or nil
  return out
end

function M.run_tool(ctx, name, args, tctx)
  if name == "base_status" then
    if not S.scanned then M.tick(ctx) end
    return status_table(ctx)
  elseif name == "base_alerts" then
    return alerts_table(ctx)
  elseif name == "base_set_rule" then
    local R = RULE_BY[args.rule]
    if not R then return "ошибка: rule — energy_low, me_full, me_lost или device_lost" end
    local r = rule(ctx, R.id)
    if args.percent ~= nil then
      if not R.pct then return "ошибка: у правила " .. R.id .. " нет порога" end
      local n = tonumber(args.percent)
      if not n or n < 1 or n > 99 then return "ошибка: percent — от 1 до 99" end
      M.action(ctx, { op = "rule_pct", rule = R.id, value = tostring(math.floor(n)) })
    end
    if args.on ~= nil and (args.on == true) ~= r.on then M.action(ctx, { op = "rule_toggle", rule = R.id }) end
    r = rule(ctx, R.id)
    return { ok = true, rule = R.id, title = R.title, on = r.on, percent = R.pct and r.pct or nil }
  end
  return "нет такого инструмента"
end

-- ---------- КПК ----------
M.radio = {
  status = function(ctx) return status_table(ctx) end,
}

-- для тестов
M._state = S
M._fmt = { num = fmt_num, rate = fmt_rate, dur = fmt_dur }

return M
