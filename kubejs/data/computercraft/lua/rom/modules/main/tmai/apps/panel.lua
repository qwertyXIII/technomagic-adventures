-- tmai.apps.panel — «Пульт»: именованные переключатели редстоуна (свет, ворота, ферма, тревога).
-- Выходы: реле редстоуна CC: Tweaked (redstone_relay) в проводной сети ЛОЦМАНа, интегратор редстоуна
-- Advanced Peripherals (redstone_integrator — в версиях AP, где он есть; методы те же) и стороны самого
-- компьютера ИИ (redstone API). Переключатель (ctx.data.switches[i]):
--   { id, name, dev = "self" | имя периферии, dtype = "self"|"relay"|"integrator", side = "top"…,
--     kind = "toggle" (вкл/выкл) | "pulse" (импульс secs с) | "lamp" (индикатор: только читает вход),
--     manual = true (только вручную: ИИ не трогает), on = что должно быть на выходе, by/at — кто и когда }
-- Терминал: свой список (Enter — переключить, → — настроить, Delete — удалить); «+ переключатель» — мастер:
--   устройство → сторона → имя → вид (→ секунды импульса) → кто может переключать.
-- Монитор: плитки «имя / ВКЛ|ВЫКЛ» (касание — переключить), листаются страницами, если не влезают.
-- Выходы ставятся заново после перезапуска ЛОЦМАНа (первый tick) и когда устройство снова на связи.
-- Группы (sw.groups, до 4: «двери», «свет») — «все двери» = группа «двери». Блокировка (sw.lock): выход держит
-- своё состояние, нажатия, ИИ и сценарии не переключают его, пока не разблокируют (вкладка, panel_lock, сценарий).
-- Инструменты ИИ: panel_list, panel_set (имя или группа), panel_group, panel_lock. КПК: radio list / set.
-- Для других приложений («Сценарии»): A.api — find/resolve/is_on/set/lock (через A.ctx реестра).

local text = require("tmai.text")
local u8 = require("tmai.u8")
local util = require("tmai.util")
local input = require("tmai.input")
local json = require("tmai.json")

local A = { id = "panel", title = "Пульт", short = "Пульт", order = 45, monitor = true, every = 5 }

local SELF = "self"
local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local SIDE_RU = { top = "верх", bottom = "низ", left = "лево", right = "право", front = "перед", back = "зад" }
local KIND_RU = { toggle = "вкл/выкл", pulse = "импульс", lamp = "индикатор" }
local MAX_SWITCHES = 48
local NAME_MAX = 24
local PULSE_MIN, PULSE_MAX = 0.5, 60

local live = {}            -- id -> { online, out, inp, pulse_end, restore, err } (не сохраняется)
local V = { mode = "list", sel = {}, top = {} }   -- вид терминала: режим, выбор и прокрутка по режимам
local MP = { page = 1 }    -- страница плиток на мониторе
local last_poll = -10

-- ---------------------------------------------------------------- данные

local function switches(ctx)
  local l = ctx.data.switches
  if type(l) ~= "table" then l = {}; ctx.data.switches = l end
  return l
end

local function L(sw)
  local s = live[sw.id]
  if not s then s = { restore = true }; live[sw.id] = s end
  return s
end

local function by_id(ctx, id)
  id = tonumber(id)
  for i, sw in ipairs(switches(ctx)) do if sw.id == id then return sw, i end end
  return nil
end

local function norm(s) return u8.lower(u8.trim(tostring(s or ""))) end

-- Найти по имени: точное совпадение (без регистра), иначе единственное, где имя содержит запрос.
local function find(ctx, name)
  local q = norm(name)
  if q == "" then return nil end
  local list = switches(ctx)
  for _, sw in ipairs(list) do if norm(sw.name) == q then return sw end end
  local hit, n = nil, 0
  for _, sw in ipairs(list) do
    if norm(sw.name):find(q, 1, true) then hit, n = sw, n + 1 end
  end
  if n == 1 then return hit end
  return nil, n > 1 and "под это имя подходят несколько" or nil
end

-- Имя: без управляющих символов, 1..NAME_MAX знаков. -> имя | nil, почему
local function clean_name(ctx, s, except_id)
  s = u8.trim((tostring(s or ""):gsub("[\1-\31\127]", " ")))
  if s == "" then return nil, "имя пустое" end
  if text.len(s) > NAME_MAX then s = u8.trim(text.sub(s, 1, NAME_MAX)) end
  for _, sw in ipairs(switches(ctx)) do
    if sw.id ~= except_id and norm(sw.name) == norm(s) then return nil, "такое имя уже есть" end
  end
  return s
end

-- Группы: в нижнем регистре, без «все » в начале («все двери» = «двери»).
local GROUPS_MAX, GROUP_LEN = 4, 16
local function norm_group(g)
  g = norm(g)
  g = g:gsub("^все%s+", "")
  return u8.trim(g)
end

-- "двери, база" | { "двери", "база" } -> { "двери", "база" } (до 4, без повторов)
local function parse_groups(v)
  local list, out, seen = {}, {}, {}
  if type(v) == "table" then list = v
  elseif v ~= nil then for part in (tostring(v) .. ","):gmatch("([^,;]*)[,;]") do list[#list + 1] = part end end
  for _, g in ipairs(list) do
    local key = norm_group(tostring(g):gsub("[\1-\31\127]", " "))
    if text.len(key) > GROUP_LEN then key = u8.trim(text.sub(key, 1, GROUP_LEN)) end
    if key ~= "" and not seen[key] and #out < GROUPS_MAX then seen[key] = true; out[#out + 1] = key end
  end
  return out
end

local function in_group(sw, g)
  for _, x in ipairs(type(sw.groups) == "table" and sw.groups or {}) do if x == g then return true end end
  return false
end

local function members(ctx, g)
  g = norm_group(g)
  local out = {}
  if g == "" then return out end
  for _, sw in ipairs(switches(ctx)) do if in_group(sw, g) then out[#out + 1] = sw end end
  return out
end

-- Имя или группа -> список переключателей | nil, почему. Имя не нашлось — пробуем как группу.
local function resolve(ctx, name, group)
  if group and tostring(group) ~= "" then
    local l = members(ctx, group)
    if #l == 0 then return nil, "в группе «" .. norm_group(group) .. "» нет переключателей" end
    return l
  end
  local sw, why = find(ctx, name)
  if sw then return { sw } end
  local l = members(ctx, name)
  if #l > 0 then return l end
  return nil, "нет переключателя «" .. tostring(name or "") .. "»" .. (why and (" (" .. why .. ")") or "")
end

-- Сторона устройства уже занята другим переключателем? (одна сторона — одно дело)
local function taken(ctx, dev, side, except_id)
  for _, sw in ipairs(switches(ctx)) do
    if sw.dev == dev and sw.side == side and sw.id ~= except_id then return sw end
  end
  return nil
end

local function secs_of(sw)
  local n = tonumber(sw.secs) or 1
  return math.max(PULSE_MIN, math.min(PULSE_MAX, n))
end

local function secs_text(n)
  n = tonumber(n) or 1
  if n == math.floor(n) then return string.format("%d с", math.floor(n)) end
  return (string.format("%.1f", n):gsub("%.", ",")) .. " с"
end

-- ---------------------------------------------------------------- устройства (МОЖНО ждать — tick/action/tool)

local function dev_type(dev)
  if dev == SELF then return type(redstone) == "table" and "self" or nil end
  if peripheral.hasType(dev, "redstone_relay") then return "relay" end
  if peripheral.hasType(dev, "redstone_integrator") then return "integrator" end
  return nil
end

local function rs_call(dev, method, side, v)
  if dev == SELF then
    if type(redstone) ~= "table" or type(redstone[method]) ~= "function" then return false, "нет redstone API" end
    return pcall(redstone[method], side, v)
  end
  if not dev_type(dev) then return false, "устройство не на связи" end
  return pcall(peripheral.call, dev, method, side, v)
end

local function set_out(sw, on)
  local s = L(sw)
  local ok, err = rs_call(sw.dev, "setOutput", sw.side, on and true or false)
  if ok then s.out, s.online, s.err = on and true or false, true, nil; return true end
  s.err = tostring(err)
  return false, s.err
end

-- Найденные выходы: { {dev, dtype}, … } (без ожидания: только имена периферии).
local function devices(ctx)
  local out = { { dev = SELF, dtype = "self" } }
  for _, n in ipairs(ctx.peripherals("redstone_relay")) do out[#out + 1] = { dev = n, dtype = "relay" } end
  for _, n in ipairs(ctx.peripherals("redstone_integrator")) do out[#out + 1] = { dev = n, dtype = "integrator" } end
  return out
end

local function dev_label(dev, dtype)
  if dev == SELF then return "Компьютер ИИ" end
  local kind = dtype == "integrator" and "Интегратор" or "Реле"
  local n = tostring(dev):match("_(%d+)$")
  if n then return kind .. " " .. n end
  if SIDE_RU[dev] then return kind .. " (" .. SIDE_RU[dev] .. ")" end
  return kind .. " " .. tostring(dev)
end

local function where(sw) return dev_label(sw.dev, sw.dtype) .. " · " .. (SIDE_RU[sw.side] or tostring(sw.side)) end

-- ---------------------------------------------------------------- состояние для экранов (НЕ ждёт)

-- -> слово, включено ли (для счёта), вид ("on"|"off"|"pulse"|"lamp"|"lost")
local function state_of(sw)
  local s = live[sw.id] or {}
  if s.online == false then return "НЕТ СВЯЗИ", false, "lost" end
  if sw.kind == "lamp" then
    if s.inp == nil then return "…", false, "off" end
    return s.inp and "ВКЛ" or "ВЫКЛ", s.inp, s.inp and "lamp" or "off"
  elseif sw.kind == "pulse" then
    if s.pulse_end then return "ИМПУЛЬС", true, "pulse" end
    return "ПУСК", false, "off"
  end
  local on = s.out
  if on == nil then on = sw.on and true or false end
  return on and "ВКЛ" or "ВЫКЛ", on, on and "on" or "off"
end

-- То же для списка: с пометкой блокировки.
local function state_word(sw)
  local word, on, look = state_of(sw)
  if sw.lock and look ~= "lost" then return word .. " блок", on, "locked" end
  return word, on, look
end

local function ago(t)
  local d = util.now() - (tonumber(t) or 0)
  if d < 60 then return "только что" end
  if d < 3600 then return math.floor(d / 60) .. " мин назад" end
  if d < 86400 then return math.floor(d / 3600) .. " ч назад" end
  return math.floor(d / 86400) .. " дн назад"
end

local function describe(sw)
  local parts = { sw.kind == "pulse" and ("импульс " .. secs_text(secs_of(sw))) or KIND_RU[sw.kind] or "?", where(sw) }
  if sw.kind ~= "lamp" then parts[#parts + 1] = sw.manual and "только вручную" or "ЛОЦМАН может переключать" end
  if sw.lock then parts[#parts + 1] = "ЗАБЛОКИРОВАН" end
  if type(sw.groups) == "table" and #sw.groups > 0 then parts[#parts + 1] = "группы: " .. table.concat(sw.groups, ", ") end
  local s = live[sw.id]
  if s and s.online == false then parts[#parts + 1] = "устройство не отвечает"
  elseif s and s.err then parts[#parts + 1] = "ошибка: " .. s.err
  elseif sw.by and sw.at then parts[#parts + 1] = tostring(sw.by) .. ", " .. ago(sw.at) end
  return table.concat(parts, " · ")
end

local function count_on(ctx)
  local on, lost = 0, 0
  local list = switches(ctx)
  for _, sw in ipairs(list) do
    local _, o, look = state_of(sw)
    if o then on = on + 1 end
    if look == "lost" then lost = lost + 1 end
  end
  return on, #list, lost
end

local function summary(ctx)
  local out = {}
  for _, sw in ipairs(switches(ctx)) do
    local word, on, look = state_of(sw)
    out[#out + 1] = { name = sw.name, kind = KIND_RU[sw.kind], on = on and true or false,
      state = look == "lost" and "нет связи" or u8.lower(word), device = dev_label(sw.dev, sw.dtype),
      side = SIDE_RU[sw.side], manual = sw.kind ~= "lamp" and (sw.manual and true or false) or nil,
      pulse_s = sw.kind == "pulse" and secs_of(sw) or nil, locked = sw.lock and true or nil,
      groups = (type(sw.groups) == "table" and #sw.groups > 0) and sw.groups or nil }
  end
  return out
end

-- ---------------------------------------------------------------- работа с выходами (МОЖНО ждать)

local function mark(ctx, sw, who)
  sw.by, sw.at = who and tostring(who) or nil, util.now()
  ctx.save()
end

-- want: true | false | nil (переключить). opts.ai — просит ИИ (или сценарий ИИ): «только вручную» — отказ.
-- -> "вкл"/"выкл"/"импульс N с" | nil, почему
local function operate(ctx, sw, want, who, opts)
  if sw.kind == "lamp" then return nil, "это индикатор: он только показывает сигнал на входе" end
  if opts and opts.ai and sw.manual then return nil, "только вручную: его переключает игрок" end
  if sw.lock then return nil, "заблокирован — сначала разблокировать" end
  local s = L(sw)
  if sw.kind == "pulse" then
    if want == false then
      if s.pulse_end then
        local ok, err = set_out(sw, false)
        if not ok then return nil, err end
        s.pulse_end = nil
      end
      return "выкл"
    end
    local ok, err = set_out(sw, true)
    if not ok then return nil, err end
    s.pulse_end = os.clock() + secs_of(sw)
    A.every = 0.5
    mark(ctx, sw, who)
    return "импульс " .. secs_text(secs_of(sw))
  end
  local on = want
  if on == nil then
    local cur = s.out
    if cur == nil then cur = sw.on end
    on = not cur
  end
  local ok, err = set_out(sw, on)
  if not ok then return nil, err end
  sw.on = on and true or false
  mark(ctx, sw, who)
  return on and "вкл" or "выкл"
end

-- Блокировка: держать текущее состояние (импульс — выключен). -> "заблокирован"/"разблокирован" | nil, почему
local function set_lock(ctx, sw, on, who, opts)
  if sw.kind == "lamp" then return nil, "индикатор нельзя заблокировать" end
  if opts and opts.ai and sw.manual then return nil, "только вручную: блокирует игрок" end
  if on then
    local s = L(sw)
    if sw.kind == "pulse" then
      if s.pulse_end or s.out then set_out(sw, false) end
      s.pulse_end, sw.on = nil, false
    else
      local cur = s.out
      if cur == nil then cur = sw.on end
      sw.on = cur and true or false
    end
    sw.lock = true
  else
    sw.lock = nil
  end
  mark(ctx, sw, who)
  return on and "заблокирован" or "разблокирован"
end

-- Опрос: вернуть выходы после перезапуска/переподключения, закончить импульсы, прочитать входы.
local function poll(ctx)
  last_poll = os.clock()
  local list = switches(ctx)
  local pulsing, changed = false, false
  for _, sw in ipairs(list) do
    local s = L(sw)
    local was = s.online
    s.online = dev_type(sw.dev) ~= nil
    if s.online then
      if was == false then s.restore = true end
      if sw.kind ~= "lamp" and s.restore then
        if sw.kind == "pulse" then s.pulse_end = nil end
        if set_out(sw, sw.kind == "toggle" and sw.on) then s.restore = nil end
      elseif sw.kind == "lamp" then
        s.restore = nil
      end
      if sw.kind == "pulse" and s.pulse_end and os.clock() >= s.pulse_end then
        if set_out(sw, false) then s.pulse_end = nil end
      end
      if sw.kind == "lamp" then
        local ok, v = rs_call(sw.dev, "getInput", sw.side)
        if ok then s.inp = v and true or false end
      elseif not s.restore then
        local ok, v = rs_call(sw.dev, "getOutput", sw.side)
        if ok then
          s.out = v and true or false
          local want = sw.kind == "toggle" and (sw.on and true or false) or false
          if sw.lock and s.out ~= want and not s.pulse_end then
            set_out(sw, want)          -- заблокирован: держим своё
          elseif sw.kind == "toggle" and s.out ~= want then
            sw.on = s.out; changed = true   -- переключил кто-то другой (программа на другом компьютере)
          end
        end
      end
    end
    if s.pulse_end then pulsing = true end
  end
  if changed then ctx.save() end
  A.every = pulsing and 0.5 or (#list > 0 and 1 or 5)
end

-- ---------------------------------------------------------------- жизненный цикл

function A.init(ctx)
  local list, keep, maxid = switches(ctx), {}, 0
  for _, sw in ipairs(list) do
    if type(sw) == "table" and type(sw.name) == "string" and SIDE_RU[sw.side] and type(sw.dev) == "string" then
      sw.kind = KIND_RU[sw.kind] and sw.kind or "toggle"
      sw.id = tonumber(sw.id)
      sw.groups = parse_groups(sw.groups)
      if sw.kind == "lamp" then sw.lock = nil end
      keep[#keep + 1] = sw
      if sw.id and sw.id > maxid then maxid = sw.id end
    end
  end
  for _, sw in ipairs(keep) do
    if not sw.id then maxid = maxid + 1; sw.id = maxid end
  end
  ctx.data.switches = keep
  ctx.data.next_id = math.max(tonumber(ctx.data.next_id) or 1, maxid + 1)
  live = {}
  for _, sw in ipairs(keep) do live[sw.id] = { restore = true } end
  V = { mode = "list", sel = {}, top = {} }
  MP.page = 1
  A.every = #keep > 0 and 1 or 5
end

function A.tick(ctx) poll(ctx) end

function A.event(ctx, name, a)
  if name == "peripheral" or name == "peripheral_detach" then
    for _, sw in ipairs(switches(ctx)) do
      if sw.dev == a and name == "peripheral" then L(sw).restore = true end
    end
    ctx.later(poll, ctx)
  elseif name == "redstone" and os.clock() - last_poll >= 0.5 then
    last_poll = os.clock()
    ctx.later(poll, ctx)
  end
end

-- Действия экрана (очередь приложений; МОЖНО ждать). Вид переключателя — поле skind (kind занят: «app»).
function A.action(ctx, act)
  local op = act.op
  local who = (act.via == "monitor" and "монитор") or act.player or "экипаж"
  if op == "tap" then
    local sw = by_id(ctx, act.id)
    if sw then
      local r, err = operate(ctx, sw, nil, who)
      if not r then
        local s = L(sw)      -- не чаще раза в 10 с на переключатель (нажимают по многу раз)
        if os.clock() - (s.warned or -100) >= 10 then s.warned = os.clock(); ctx.say("Пульт: «" .. sw.name .. "» — " .. tostring(err), "warn") end
      end
    end
  elseif op == "groups" then
    local sw = by_id(ctx, act.id)
    if not sw then return end
    sw.groups = parse_groups(act.value)
    ctx.save()
  elseif op == "lock" then
    local sw = by_id(ctx, act.id)
    if not sw then return end
    local r, err = set_lock(ctx, sw, act.value and true or false, who)
    if not r then ctx.say("Пульт: «" .. sw.name .. "» — " .. tostring(err), "warn") end
  elseif op == "add" then
    local list = switches(ctx)
    if #list >= MAX_SWITCHES then ctx.say("Пульт: не больше " .. MAX_SWITCHES .. " переключателей.", "warn"); return end
    local name, why = clean_name(ctx, act.name)
    if not name then ctx.say("Пульт: " .. why .. ".", "warn"); return end
    if not SIDE_RU[act.side] or type(act.dev) ~= "string" then return end
    local busy = taken(ctx, act.dev, act.side)
    if busy then ctx.say("Пульт: эта сторона уже занята — «" .. busy.name .. "».", "warn"); return end
    local id = math.max(tonumber(ctx.data.next_id) or 1, 1)
    ctx.data.next_id = id + 1
    local sw = { id = id, name = name, dev = act.dev, dtype = act.dtype or dev_type(act.dev) or "relay", side = act.side,
      kind = KIND_RU[act.skind] and act.skind or "toggle", manual = act.manual and true or false, on = false }
    if sw.kind == "pulse" then sw.secs = math.max(PULSE_MIN, math.min(PULSE_MAX, tonumber(act.secs) or 1)) end
    list[#list + 1] = sw
    live[sw.id] = { restore = true }
    ctx.save()
    poll(ctx)
  elseif op == "del" then
    local sw, i = by_id(ctx, act.id)
    if not sw then return end
    if sw.kind ~= "lamp" then set_out(sw, false) end
    table.remove(switches(ctx), i)
    live[sw.id] = nil
    ctx.save()
  elseif op == "rename" then
    local sw = by_id(ctx, act.id)
    if not sw then return end
    local name, why = clean_name(ctx, act.value, sw.id)
    if not name then ctx.say("Пульт: " .. why .. ".", "warn"); return end
    sw.name = name
    ctx.save()
  elseif op == "kind" then
    local sw = by_id(ctx, act.id)
    if not sw or not KIND_RU[act.skind] or sw.kind == act.skind then return end
    if sw.kind ~= "lamp" then set_out(sw, false) end
    sw.kind, sw.on = act.skind, false
    if sw.kind == "pulse" then sw.secs = sw.secs or 1 end
    L(sw).pulse_end, L(sw).restore = nil, true
    ctx.save()
    poll(ctx)
  elseif op == "secs" then
    local sw = by_id(ctx, act.id)
    local n = tonumber((tostring(act.value or ""):gsub(",", ".")))
    if not sw or not n then return end
    sw.secs = math.max(PULSE_MIN, math.min(PULSE_MAX, n))
    ctx.save()
  elseif op == "manual" then
    local sw = by_id(ctx, act.id)
    if not sw then return end
    sw.manual = act.value and true or false
    ctx.save()
  elseif op == "move" then
    local sw = by_id(ctx, act.id)
    if not sw or not SIDE_RU[act.side] or type(act.dev) ~= "string" then return end
    local busy = taken(ctx, act.dev, act.side, sw.id)
    if busy then ctx.say("Пульт: эта сторона уже занята — «" .. busy.name .. "».", "warn"); return end
    if sw.kind ~= "lamp" then set_out(sw, false) end
    sw.dev, sw.dtype, sw.side = act.dev, act.dtype or dev_type(act.dev) or "relay", act.side
    live[sw.id] = { restore = true }
    ctx.save()
    poll(ctx)
  end
end

-- ---------------------------------------------------------------- «Главная», нейросеть, КПК

function A.status(ctx)
  local on, n, lost = count_on(ctx)
  if n == 0 then return "нет переключателей" end
  local s = "вкл " .. on .. " из " .. n
  if lost > 0 then s = s .. ", сбой " .. lost end
  return s
end

local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end

function A.tools(ctx)
  if #switches(ctx) == 0 then return {} end
  local NAME = { type = "string", description = "имя переключателя (или группа: «двери», «все двери»)" }
  local GROUP = { type = "string", description = "группа вместо имени — все её переключатели" }
  return {
    { name = "panel_list", description = "Пульт экипажа: именованные переключатели редстоуна (свет, ворота, фермы) и индикаторы, их состояние и группы. manual=true — только вручную, ЛОЦМАН их не трогает; locked=true — заблокирован.",
      parameters = obj({}) },
    { name = "panel_set", description = "Переключить выключатель пульта по имени или всю группу. Отказ — для «только вручную», заблокированных и индикаторов.",
      parameters = obj({ name = NAME, group = GROUP,
        state = { type = "string", enum = { "on", "off", "toggle", "pulse" }, description = "on/off/toggle; для импульсного — pulse (или off — прервать)" } },
        { "state" }) },
    { name = "panel_group", description = "Задать группы переключателя (до 4, через запятую: «двери, база»); пусто — убрать из групп. «Все двери» = группа «двери».",
      parameters = obj({ name = { type = "string", description = "имя переключателя" },
        groups = { type = "string", description = "группы через запятую" } }, { "name", "groups" }) },
    { name = "panel_lock", description = "Заблокировать (lock=true: держит текущее состояние, нажатия и ИИ не переключают) или разблокировать переключатель или группу.",
      parameters = obj({ name = NAME, group = GROUP, lock = { type = "boolean", description = "true — заблокировать, false — снять" } },
        { "lock" }) },
  }
end

-- Применить fn к каждому из списка -> { results = { {name, state | error}, … } } (один — без списка).
local function each(list, fn)
  local res = {}
  for _, sw in ipairs(list) do
    local r, err = fn(sw)
    res[#res + 1] = r and { name = sw.name, state = r } or { name = sw.name, error = tostring(err) }
  end
  if #res == 1 then
    if res[1].error then return "отказ: «" .. res[1].name .. "» — " .. res[1].error end
    return res[1]
  end
  return { results = res }
end

function A.run_tool(ctx, name, args, tctx)
  local who = "ЛОЦМАН" .. (tctx and tctx.player and (" для " .. tostring(tctx.player)) or "")
  if name == "panel_list" then
    return { switches = summary(ctx) }
  elseif name == "panel_set" then
    local list, why = resolve(ctx, args.name, args.group)
    if not list then return "отказ: " .. tostring(why) .. "; список — panel_list" end
    local st = tostring(args.state or "toggle"):lower()
    local want = nil
    if st == "on" then want = true elseif st == "off" then want = false end
    return each(list, function(sw)
      if sw.kind == "lamp" then return nil, "индикатор, он только показывает сигнал" end
      if sw.kind == "toggle" and st == "pulse" then return nil, "обычный выключатель: on, off или toggle" end
      return operate(ctx, sw, want, who, { ai = true })
    end)
  elseif name == "panel_group" then
    local sw, why = find(ctx, args.name)
    if not sw then return "отказ: нет переключателя «" .. tostring(args.name or "") .. "»" .. (why and (" (" .. why .. ")") or "") end
    sw.groups = parse_groups(args.groups)
    ctx.save()
    return { name = sw.name, groups = sw.groups }
  elseif name == "panel_lock" then
    local list, why = resolve(ctx, args.name, args.group)
    if not list then return "отказ: " .. tostring(why) .. "; список — panel_list" end
    return each(list, function(sw) return set_lock(ctx, sw, args.lock and true or false, who, { ai = true }) end)
  end
  return "нет такого инструмента"
end

A.radio = {
  list = function(ctx) return { switches = summary(ctx) } end,
  set = function(ctx, msg, sender, player)
    local list, why
    if msg.id then local sw = by_id(ctx, msg.id); list = sw and { sw } or nil
    else list, why = resolve(ctx, msg.name, msg.group) end
    if not list then return nil, why or "нет такого переключателя" end
    local want = nil
    if msg.state == "on" then want = true elseif msg.state == "off" then want = false end
    local res = {}
    for _, sw in ipairs(list) do
      local r, err = operate(ctx, sw, want, player or ("КПК " .. tostring(sender)))
      if #list == 1 and not r then return nil, err end
      res[#res + 1] = { name = sw.name, state = r, error = err }
    end
    if #res == 1 then return res[1] end
    return { results = res }
  end,
}

-- ---------------------------------------------------------------- для других приложений («Сценарии»)
-- Все функции, кроме find/resolve/is_on/list, можно звать только там, где можно ждать (действие, tick).
A.api = {
  list = function() return A.ctx and switches(A.ctx) or {} end,
  find = function(name) if not A.ctx then return nil end return find(A.ctx, name) end,
  members = function(group) if not A.ctx then return {} end return members(A.ctx, group) end,
  resolve = function(name, group)
    if not A.ctx then return nil, "приложения «Пульт» нет" end
    return resolve(A.ctx, name, group)
  end,
  -- включён ли (для выходов — что на выходе, для индикатора — вход); nil — нет связи / ещё не прочитан
  is_on = function(sw)
    local s = live[sw.id] or {}
    if s.online == false then return nil end
    if sw.kind == "lamp" then return s.inp end
    if sw.kind == "pulse" then return s.pulse_end ~= nil end
    if s.out ~= nil then return s.out end
    return sw.on and true or false
  end,
  -- state: "on" | "off" | "toggle" | "pulse"; opts.ai — «только вручную» не трогать
  set = function(sw, state, who, opts)
    if not A.ctx then return nil, "приложения «Пульт» нет" end
    if sw.kind == "toggle" and state == "pulse" then return nil, "обычный выключатель: on, off или toggle" end
    local want = nil
    if state == "on" then want = true elseif state == "off" then want = false end
    return operate(A.ctx, sw, want, who, opts)
  end,
  lock = function(sw, on, who, opts)
    if not A.ctx then return nil, "приложения «Пульт» нет" end
    return set_lock(A.ctx, sw, on, who, opts)
  end,
}

-- ---------------------------------------------------------------- терминал: экраны (НЕ ждёт)

local function set_mode(mode, keep_sel)
  V.mode = mode
  if not keep_sel then V.sel[mode], V.top[mode] = nil, nil end
end

local function start_input(prompt, value, max, placeholder)
  V.ed = input.new({ term = term, x = 1, y = 1, width = 51, prompt = prompt, max = max or NAME_MAX, history = false,
    placeholder = placeholder, fg = colors.white, bg = colors.black, prompt_fg = colors.yellow,
    placeholder_fg = colors.gray })
  if value and value ~= "" then V.ed:set(value) end
  V.err = nil
end

-- Строки экрана: { text, mid (серым), right, rfg, fg, sel = true (можно выбрать), desc, … }
local function screen(ctx)
  local list = switches(ctx)
  local W = V.w or {}
  local edit = W.edit_id and by_id(ctx, W.edit_id)
  local m = V.mode
  if m == "list" then
    local on, n = count_on(ctx)
    local items = {}
    for _, sw in ipairs(list) do
      local word, _, look = state_word(sw)
      local rfg = ({ on = colors.lime, lamp = colors.yellow, pulse = colors.orange, lost = colors.red, locked = colors.magenta })[look] or colors.lightGray
      items[#items + 1] = { text = sw.name, mid = where(sw), right = word, rfg = rfg, sel = true, sw = sw, desc = describe(sw) }
    end
    if #list == 0 then
      items[#items + 1] = { text = "Пульт пуст: добавьте выход реле или стороны компьютера.", fg = colors.gray }
    end
    if #list < MAX_SWITCHES then
      items[#items + 1] = { text = "+ переключатель", fg = colors.cyan, sel = true, add = true,
        desc = "Выход редстоуна (свет, ворота, ферма) или индикатор входа" }
    end
    return { title = "Переключатели", right = n > 0 and ("вкл " .. on .. " из " .. n) or nil, items = items }
  elseif m == "dev" then
    local items = {}
    local relays = 0
    for _, d in ipairs(devices(ctx)) do
      local note = d.dev == SELF and "его стороны" or d.dev
      if d.dev ~= SELF then relays = relays + 1 end
      items[#items + 1] = { text = dev_label(d.dev, d.dtype), mid = note, sel = true, dev = d.dev, dtype = d.dtype,
        desc = d.dev == SELF and "Редстоун прямо со сторон компьютера ИИ" or "Редстоун-ретранслятор (CC: Tweaked) в сети ЛОЦМАНа" }
    end
    if relays == 0 then
      items[#items + 1] = { text = "Ретранслятор не найден: поставьте его вплотную", fg = colors.gray }
      items[#items + 1] = { text = "к компьютеру ИИ или подключите модемом и кабелем.", fg = colors.gray }
    end
    return { title = (edit and ("«" .. edit.name .. "»: устройство") or "Новый переключатель · 1/4 устройство"), items = items }
  elseif m == "side" then
    local items = {}
    local here = {}
    for _, n in ipairs(peripheral.getNames()) do here[n] = true end
    for _, side in ipairs(SIDES) do
      local busy = taken(ctx, W.dev, side, W.edit_id)
      local note = busy and ("занято: " .. busy.name) or nil
      if not note and W.dev == SELF and here[side] then note = "там устройство" end
      items[#items + 1] = { text = SIDE_RU[side] .. " (" .. side .. ")", right = note, rfg = busy and colors.gray or colors.orange,
        fg = busy and colors.gray or nil, sel = not busy, side = side,
        desc = W.dev == SELF and "Сторона компьютера ИИ: перед — где его экран" or "Сторона ретранслятора: перед — его лицевая сторона" }
    end
    return { title = (edit and ("«" .. edit.name .. "»: сторона") or "Новый · 2/4 сторона") .. " · " .. dev_label(W.dev, W.dtype), items = items }
  elseif m == "name" then
    return { title = edit and ("«" .. edit.name .. "»: новое имя") or ("Новый · 3/4 имя · " .. dev_label(W.dev, W.dtype) .. " · " .. tostring(SIDE_RU[W.side])),
      items = { { text = "Коротко и понятно: «Свет в шахте», «Ворота», «Ферма».", fg = colors.lightGray },
        { text = "По имени переключатель найдёт и ЛОЦМАН.", fg = colors.lightGray } },
      input = true }
  elseif m == "kind" then
    return { title = edit and ("«" .. edit.name .. "»: вид") or ("Новый · 4/4 вид · «" .. tostring(W.name) .. "»"), items = {
      { text = "Вкл/выкл", mid = "держит сигнал", sel = true, kind = "toggle", desc = "Свет, ферма, насос: включён, пока не выключат" },
      { text = "Импульс", mid = "сигнал на N секунд", sel = true, kind = "pulse", desc = "Ворота, раздатчик, звонок: короткий сигнал по нажатию" },
      { text = "Индикатор", mid = "только показывает вход", sel = true, kind = "lamp", desc = "Читает сигнал на входе: датчик, наблюдатель, рычаг" },
    } }
  elseif m == "secs" then
    return { title = (edit and ("«" .. edit.name .. "»") or ("Новый · «" .. tostring(W.name) .. "»")) .. ": длина импульса",
      items = { { text = "Секунды: от 0,5 до 60 (например, 1 или 2,5).", fg = colors.lightGray } }, input = true }
  elseif m == "groups" and edit then
    return { title = "«" .. edit.name .. "»: группы",
      items = { { text = "Через запятую, до 4: «двери, база». Пусто — без групп.", fg = colors.lightGray },
        { text = "«Закрой все двери» — это группа «двери».", fg = colors.lightGray } }, input = true }
  elseif m == "who" then
    return { title = "Новый · «" .. tostring(W.name) .. "»: кто переключает", items = {
      { text = "Экипаж и ЛОЦМАН", sel = true, manual = false, desc = "ЛОЦМАН сможет переключать по просьбе: «включи свет в шахте»" },
      { text = "Только вручную", mid = "ЛОЦМАН не трогает", sel = true, manual = true, desc = "Ворота базы, реактор: только игрок на пульте" },
    } }
  elseif m == "menu" and edit then
    local items = {
      { text = "Переименовать", mid = edit.name, sel = true, go = "rename" },
      { text = "Вид", mid = KIND_RU[edit.kind], sel = true, go = "kind" },
    }
    if edit.kind == "pulse" then items[#items + 1] = { text = "Длина импульса", mid = secs_text(secs_of(edit)), sel = true, go = "secs" } end
    if edit.kind ~= "lamp" then
      items[#items + 1] = { text = "Кто переключает", mid = edit.manual and "только вручную" or "экипаж и ЛОЦМАН", sel = true, go = "manual",
        desc = "Enter — сменить" }
      items[#items + 1] = { text = "Блокировка", mid = edit.lock and "заблокирован" or "нет", sel = true, go = "lock",
        desc = edit.lock and "Enter — разблокировать" or "Enter — заблокировать: держит состояние, нажатия не действуют" }
    end
    items[#items + 1] = { text = "Группы", mid = (type(edit.groups) == "table" and #edit.groups > 0) and table.concat(edit.groups, ", ") or "нет",
      sel = true, go = "groups", desc = "«двери», «свет»… — чтобы управлять сразу всеми: «закрой все двери»" }
    items[#items + 1] = { text = "Устройство и сторона", mid = where(edit), sel = true, go = "move" }
    items[#items + 1] = { text = "Удалить", fg = colors.red, sel = true, go = "del" }
    items[#items + 1] = { text = "← назад", fg = colors.lightGray, sel = true, go = "back" }
    return { title = "«" .. edit.name .. "»: настройка", items = items }
  elseif m == "del" and edit then
    return { title = "Удалить «" .. edit.name .. "»?", items = {
      { text = "Нет, оставить", sel = true, go = "back" },
      { text = "Да, удалить", fg = colors.red, sel = true, go = "yes", desc = edit.kind ~= "lamp" and "Выход выключится" or nil },
    } }
  end
  set_mode("list")
  return screen(ctx)
end

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

local function back(ctx)
  local m = V.mode
  local W = V.w or {}
  V.err = nil
  if m == "list" then return end
  if m == "side" then set_mode("dev", true); return end
  if W.edit_id then   -- правка существующего: назад — в его настройки (или в список, откуда пришли)
    V.ed = nil
    if m == "menu" or W.from == "list" then set_mode("list", true) else set_mode("menu", true) end
    return
  end
  V.ed = nil
  if m == "name" then set_mode("side", true)
  elseif m == "kind" then set_mode("name", true); start_input("Имя: ", W.name, NAME_MAX, "например: Свет в шахте")
  elseif m == "secs" then set_mode("kind", true)
  elseif m == "who" then
    if W.kind == "pulse" then set_mode("secs", true); start_input("Секунд: ", tostring(W.secs or 1), 5, "1")
    else set_mode("kind", true) end
  else set_mode("list", true) end
end

-- Enter на строке экрана -> действие в очередь или nil (смена экрана здесь же).
local function choose(ctx, scr, it)
  local m = V.mode
  local W = V.w or {}
  if m == "list" then
    if it.add then
      V.w = {}
      set_mode("dev")
      return nil
    end
    if it.sw then
      if it.sw.kind == "lamp" then V.err = "Индикатор только показывает вход: → — настроить"; return nil end
      if it.sw.lock then V.err = "«" .. it.sw.name .. "» заблокирован: → — разблокировать"; return nil end
      return { op = "tap", id = it.sw.id }
    end
  elseif m == "dev" then
    W.dev, W.dtype = it.dev, it.dtype
    V.w = W
    set_mode("side")
  elseif m == "side" then
    W.side = it.side
    if W.edit_id then
      set_mode("menu", true)
      return { op = "move", id = W.edit_id, dev = W.dev, dtype = W.dtype, side = W.side }
    end
    set_mode("name")
    start_input("Имя: ", W.name, NAME_MAX, "например: Свет в шахте")
  elseif m == "kind" then
    if W.edit_id then
      set_mode("menu", true)
      return { op = "kind", id = W.edit_id, skind = it.kind }
    end
    W.kind = it.kind
    if it.kind == "pulse" then
      set_mode("secs")
      start_input("Секунд: ", tostring(W.secs or 1), 5, "1")
    elseif it.kind == "lamp" then
      set_mode("list", true)
      return { op = "add", name = W.name, dev = W.dev, dtype = W.dtype, side = W.side, skind = "lamp" }
    else
      set_mode("who")
    end
  elseif m == "who" then
    set_mode("list", true)
    return { op = "add", name = W.name, dev = W.dev, dtype = W.dtype, side = W.side, skind = W.kind, secs = W.secs,
      manual = it.manual }
  elseif m == "menu" then
    local sw = by_id(ctx, W.edit_id)
    if not sw then set_mode("list", true); return nil end
    if it.go == "rename" then set_mode("name"); start_input("Имя: ", sw.name, NAME_MAX, "новое имя")
    elseif it.go == "kind" then set_mode("kind")
    elseif it.go == "secs" then set_mode("secs"); start_input("Секунд: ", tostring(secs_of(sw)), 5, "1")
    elseif it.go == "manual" then return { op = "manual", id = sw.id, value = not sw.manual }
    elseif it.go == "lock" then return { op = "lock", id = sw.id, value = not sw.lock }
    elseif it.go == "groups" then
      set_mode("groups")
      start_input("Группы: ", table.concat(type(sw.groups) == "table" and sw.groups or {}, ", "), 70, "двери, база")
    elseif it.go == "move" then W.dev, W.dtype = sw.dev, sw.dtype; set_mode("dev")
    elseif it.go == "del" then W.from = nil; set_mode("del")
    elseif it.go == "back" then set_mode("list", true) end
  elseif m == "del" then
    if it.go == "yes" then
      local id = W.edit_id
      V.w = {}
      set_mode("list", true)
      return { op = "del", id = id }
    end
    back(ctx)
  end
  return nil
end

-- Введённая строка (имя / секунды) -> действие или nil.
local function submit(ctx, txt)
  local m = V.mode
  local W = V.w or {}
  if m == "name" then
    local name, why = clean_name(ctx, txt, W.edit_id)
    if not name then V.err = why; return nil end
    if W.edit_id then
      set_mode("menu", true)
      V.ed = nil
      return { op = "rename", id = W.edit_id, value = name }
    end
    W.name = name
    V.ed = nil
    set_mode("kind")
  elseif m == "secs" then
    local n = tonumber((u8.trim(tostring(txt or "")):gsub(",", ".")))
    if not n or n < PULSE_MIN or n > PULSE_MAX then V.err = "нужно число от 0,5 до 60"; return nil end
    V.ed = nil
    if W.edit_id then
      set_mode("menu", true)
      return { op = "secs", id = W.edit_id, value = n }
    end
    W.secs = n
    set_mode("who")
  elseif m == "groups" then
    V.ed = nil
    set_mode("menu", true)
    return { op = "groups", id = W.edit_id, value = txt }
  end
  return nil
end

-- Строка списка: «> имя      где      СОСТОЯНИЕ» ровно в ширину w.
local function draw_row(ctx, t, x, yy, w, it, cur, rcol)
  local bg = cur and colors.gray or colors.black
  local prefix = it.sel and (cur and "> " or "  ") or "  "
  local rw = it.right and math.min(w - 3, math.max(text.len(it.right), it.sw and rcol or 0)) or 0
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

local function draw_screen(ctx, t, x, y, w, h)
  V.area = { x = x, y = y, w = w, h = h }
  local scr = screen(ctx)
  local items = scr.items
  local sel = fix_sel(items)
  -- заголовок
  local right = scr.right or ""
  local rl = (right ~= "" and text.len(right) + 1 < w - 4) and text.len(right) or 0
  ctx.put(t, x, y, text.fit(scr.title, w - (rl > 0 and rl + 1 or 0), ".."), colors.cyan, colors.black)
  if rl > 0 then ctx.put(t, x + w - rl - 1, y, " " .. right, colors.lightGray, colors.black) end
  -- строки
  local rows = math.max(0, h - 2)
  local top = V.top[V.mode] or 1
  if sel < top then top = sel end
  if sel > top + rows - 1 then top = sel - rows + 1 end
  top = math.max(1, math.min(top, math.max(1, #items - rows + 1)))
  V.top[V.mode] = top
  local rcol = 0      -- столбец состояний — по самому длинному слову
  for _, it in ipairs(items) do if it.sw and it.right then rcol = math.max(rcol, text.len(it.right)) end end
  for i = top, math.min(#items, top + rows - 1) do
    draw_row(ctx, t, x, y + 1 + i - top, w, items[i], i == sel and items[i].sel, rcol)
  end
  if h < 2 then return end
  -- низ: ввод или описание выбранного
  local by = y + h - 1
  if scr.input and V.ed then
    if V.err then ctx.put(t, x, by - 1, text.fit(V.err, w), colors.red, colors.black) end
    local e = V.ed
    e.t = t
    e:move(x, by, w)
    e:draw()
    t.setCursorBlink(false)      -- курсор вернёт ui после подсказки (A.cursor)
  else
    local it = items[sel]
    local d = V.err or (it and it.sel and it.desc) or ""
    ctx.put(t, x, by, text.fit(d, w, ".."), V.err and colors.orange or colors.lightGray, colors.black)
  end
end

-- ---------------------------------------------------------------- монитор: плитки (НЕ ждёт)

local MINW, MINH, MAXW, MAXH = 7, 2, 32, 12

-- Сетка плиток для n переключателей в области w×h: { cols, rows, tw, th, per, paged, ox, oy }.
local function grid(w, h, n)
  n = math.max(1, n)
  local best
  for cols = 1, math.max(1, math.floor((w + 1) / (MINW + 1))) do
    local tw = math.floor((w - (cols - 1)) / cols)
    local rows = math.ceil(n / cols)
    local th = math.floor((h - (rows - 1)) / rows)
    if tw >= MINW and th >= MINH then
      local cw, ch = math.min(tw, MAXW), math.min(th, MAXH)
      local score = math.min(cw / 1.5, ch)   -- клетка шрифта выше, чем шире: 1.5 знака ≈ 1 строка
      local area = cw * ch
      if not best or score > best.score + 0.01 or (math.abs(score - best.score) <= 0.01 and area > best.area) then
        best = { cols = cols, rows = rows, tw = cw, th = ch, score = score, area = area }
      end
    end
  end
  local g = best
  if not g then   -- не влезают все: страницы, нижняя строка — листать
    local hh = math.max(1, h - 1)
    local cols = math.max(1, math.floor((w + 1) / (MINW + 1)))
    local tw = math.max(1, math.floor((w - (cols - 1)) / cols))
    local rows = math.max(1, math.floor((hh + 1) / (MINH + 1)))
    local th = math.max(1, math.floor((hh - (rows - 1)) / rows))
    g = { cols = cols, rows = rows, tw = math.min(tw, MAXW), th = math.min(th, MAXH), paged = true }
  end
  g.per = g.cols * g.rows
  local gw = g.cols * g.tw + (g.cols - 1)
  local gh = g.rows * g.th + (g.rows - 1)
  g.ox = math.max(0, math.floor((w - gw) / 2))
  g.oy = g.paged and 0 or math.max(0, math.floor((h - gh) / 2))
  return g
end

local function centered(s, w)
  local l = text.len(s)
  if l >= w then return text.fit(s, w) end
  local lp = math.floor((w - l) / 2)
  return text.fit((" "):rep(lp) .. s, w)
end

local LOOK = {
  on = { colors.green, colors.white }, lamp = { colors.yellow, colors.black }, pulse = { colors.orange, colors.black },
  lost = { colors.red, colors.white }, off = { colors.gray, colors.white }, locked = { colors.magenta, colors.white },
}

local function draw_tile(ctx, t, x, y, w, h, sw)
  local word, _, look = state_of(sw)
  if sw.lock and look ~= "lost" then look = "locked"; word = word .. " БЛОК" end
  local c = LOOK[look] or LOOK.off
  local bg, fg = c[1], c[2]
  for yy = y, y + h - 1 do ctx.bar(t, x, yy, w, bg) end
  local pad = w >= 10 and 1 or 0
  local iw = math.max(1, w - 2 * pad)
  if text.len(word) > iw then word = ({ ["НЕТ СВЯЗИ"] = "НЕТ", ["ИМПУЛЬС"] = "ИМП" })[word] or (sw.lock and "БЛОК") or word end
  if h == 1 then
    local wl = text.len(word)
    if iw < wl + 2 then ctx.put(t, x + pad, y, text.fit(word, iw), fg, bg)
    else ctx.put(t, x + pad, y, text.fit(sw.name, iw - wl - 1, "..") .. " " .. word, fg, bg) end
    return
  end
  local lines = text.wrap(sw.name, iw)
  local maxn = h - 1
  if #lines > maxn then
    local cut = {}
    for i = 1, maxn do cut[i] = lines[i] end
    cut[maxn] = text.fit(lines[maxn] .. " " .. lines[maxn + 1], iw, "..")
    lines = cut
  end
  local top = y + math.floor((h - (#lines + 1)) / 2)
  for i, l in ipairs(lines) do ctx.put(t, x + pad, top + i - 1, centered(l, iw), fg, bg) end
  ctx.put(t, x + pad, top + #lines, centered(word, iw), fg, bg)
end

local function draw_tiles(ctx, t, x, y, w, h)
  local list = switches(ctx)
  if #list == 0 then
    local lines = text.wrap("Пульт пуст. Переключатели добавляют на терминале ИИ: вкладка «Пульт», «+ переключатель».", w)
    for i = 1, math.min(#lines, h) do ctx.put(t, x, y + i - 1, text.fit(lines[i], w), colors.gray, colors.black) end
    return
  end
  local g = grid(w, h, #list)
  local pages = math.max(1, math.ceil(#list / g.per))
  if MP.page > pages then MP.page = pages end
  if MP.page < 1 then MP.page = 1 end
  local first = (MP.page - 1) * g.per
  for k = 0, g.per - 1 do
    local sw = list[first + k + 1]
    if not sw then break end
    local col, row = k % g.cols, math.floor(k / g.cols)
    draw_tile(ctx, t, x + g.ox + col * (g.tw + 1), y + g.oy + row * (g.th + 1), g.tw, g.th, sw)
  end
  if g.paged then
    ctx.put(t, x, y + h - 1, centered("◄  " .. MP.page .. "/" .. pages .. "  ►", w), colors.white, colors.black)
  end
end

-- ---------------------------------------------------------------- договор приложения: draw/key/touch/hint

function A.draw(ctx, t, x, y, w, h, where_)
  if where_ == "monitor" then draw_tiles(ctx, t, x, y, w, h) else draw_screen(ctx, t, x, y, w, h) end
end

function A.touch(ctx, x, y, w, h)
  local list = switches(ctx)
  if #list == 0 then return nil end
  local g = grid(w, h, #list)
  local pages = math.max(1, math.ceil(#list / g.per))
  if g.paged and y == h then
    if x <= w / 2 then MP.page = MP.page - 1 else MP.page = MP.page + 1 end
    if MP.page < 1 then MP.page = pages elseif MP.page > pages then MP.page = 1 end
    return nil
  end
  local rx, ry = x - 1 - g.ox, y - 1 - g.oy
  if rx < 0 or ry < 0 then return nil end
  local col, row = math.floor(rx / (g.tw + 1)), math.floor(ry / (g.th + 1))
  if col >= g.cols or row >= g.rows or rx % (g.tw + 1) == g.tw or ry % (g.th + 1) == g.th then return nil end
  local sw = list[(MP.page - 1) * g.per + row * g.cols + col + 1]
  if not sw or sw.kind == "lamp" then return nil end
  return { op = "tap", id = sw.id, via = "monitor" }
end

function A.key(ctx, ev, a, b, c)
  local scr = screen(ctx)
  if scr.input and V.ed then
    if ev == "key" and a == keys.up then V.ed = nil; back(ctx); return true end
    local r, txt = V.ed:handle(ev, a, b, c)
    if r == "submit" then return true, submit(ctx, txt) end
    if r ~= nil then V.err = nil end
    return r ~= nil
  end
  local items = scr.items
  local rows = math.max(1, ((V.area and V.area.h) or 16) - 2)
  if ev == "key" then
    if a ~= keys.enter and a ~= keys.leftShift and a ~= keys.rightShift then V.err = nil end
    if a == keys.up then move_sel(items, -1)
    elseif a == keys.down then move_sel(items, 1)
    elseif a == keys.pageUp then move_sel(items, -1, rows - 1)
    elseif a == keys.pageDown then move_sel(items, 1, rows - 1)
    elseif a == keys.home then V.sel[V.mode] = 1; fix_sel(items)
    elseif a == keys.enter then
      local it = items[fix_sel(items)]
      if not it or not it.sel then return true end
      V.err = nil
      return true, choose(ctx, scr, it)
    elseif a == keys.backspace or a == keys.left then back(ctx)
    elseif a == keys.right and V.mode == "list" then
      local it = items[fix_sel(items)]
      if it and it.sw then V.w = { edit_id = it.sw.id }; set_mode("menu") end
    elseif a == keys.delete and V.mode == "list" then
      local it = items[fix_sel(items)]
      if it and it.sw then V.w = { edit_id = it.sw.id, from = "list" }; set_mode("del") end
    elseif a == keys.delete and V.mode == "del" then
      local it = { go = "yes" }
      return true, choose(ctx, scr, it)
    else
      return false
    end
    return true
  elseif ev == "mouse_scroll" then
    move_sel(items, a > 0 and 1 or -1)
    return true
  elseif ev == "mouse_click" and V.area then
    local ar = V.area
    local i = (V.top[V.mode] or 1) + (c - ar.y - 1)
    if c > ar.y and c < ar.y + ar.h - 1 and b >= ar.x and b < ar.x + ar.w and selectable(items, i) then
      if V.sel[V.mode] == i then return true, choose(ctx, scr, items[i]) end
      V.sel[V.mode] = i
      return true
    end
  end
  return false
end

-- Где мигать курсором (ui зовёт после своей строки подсказки): строка ввода имени/секунд/групп.
function A.cursor(ctx)
  local e = V.ed
  if not e or not V.area or not screen(ctx).input then return nil end
  local cx = e.x + text.len(e.prompt) + e.pos - e.scroll
  if cx < V.area.x or cx > V.area.x + V.area.w - 1 then return nil end
  return cx, e.y
end

function A.hint(ctx)
  local m = V.mode
  if m == "list" then
    local scr = screen(ctx)
    local it = scr.items[V.sel.list or 0]
    if it and it.sw then
      if it.sw.kind == "lamp" then return "→ — настроить · Delete — удалить" end
      return "Enter — переключить · → — настроить · Del — удалить"
    end
    return "↑↓ — выбор · Enter — добавить"
  end
  if m == "name" or m == "secs" or m == "groups" then return "Enter — готово · ↑ — назад" end
  if m == "del" then return "Enter — выбрать · Backspace — отмена" end
  return "↑↓ — выбор · Enter — дальше · Backspace — назад"
end

return A
