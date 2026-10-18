-- tmai.quests — побочные задания ИИ. Нейросеть только ВЫБИРАЕТ задание из заранее
-- заданного списка и озвучивает его; проверку и награду делает программа.
-- /rom/tmai/quests.tsv: id, title, type, target, count, min_repair, reward, hint
--   type = deliver — принести target (ID предмета) x count в грузовой отсек капсулы
--          visit   — дойти до цели разведки target (ID из scout.tsv); координаты даёт TM-NAV
--          kill    — убить count мобов target (ID сущности), счёт ведёт TM-NAV через scoreboard
-- reward — ID награды из rewards.tsv (выдаёт TM-NAV командой /give, один раз на задание).
-- Невыданная награда (модуль не ответил, непонятно кому) ждёт в state.quests.unpaid и выдаётся при следующей проверке.

local util = require("tmai.util")
local link = require("tmai.link")

local M = {}

local list, by_id = {}, {}
local state, cargo_fn, core_name_fn, player_fn

-- Ник Minecraft (как who.valid; модуль не тянет who, чтобы не зависеть от периферии).
local function valid(name)
  return type(name) == "string" and #name >= 3 and #name <= 16 and name:match("^[%w_]+$") ~= nil
end

-- get_cargo() -> инвентарь Ящика памяти, его имя; get_core_name(имя ящика) -> ядро, видимое из ящика | nil, почему;
-- get_player() — ник того, кто сейчас у терминала, или nil.
function M.init(st, get_cargo, get_core_name, get_player)
  state = st
  state.quests = state.quests or { done = {}, active = nil }
  state.quests.unpaid = state.quests.unpaid or {}
  cargo_fn, core_name_fn, player_fn = get_cargo, get_core_name, get_player
  list, by_id = {}, {}
  for _, r in ipairs(util.read_tsv(util.ROM_DIR .. "/quests.tsv")) do
    r.count = tonumber(r.count) or 1
    r.min_repair = tonumber(r.min_repair) or 0
    list[#list + 1] = r
    by_id[r.id] = r
  end
end

function M.available(repair)
  local out = {}
  for _, q in ipairs(list) do
    if not state.quests.done[q.id] and q.min_repair <= (repair or 0) then
      out[#out + 1] = { id = q.id, title = q.title, type = q.type, target = q.target, count = q.count, hint = q.hint }
    end
  end
  return out
end

function M.active()
  local a = state.quests.active
  if not a then return nil end
  local q = by_id[a.id]
  return { id = a.id, title = q and q.title, type = q and q.type, target = q and q.target,
    count = q and q.count, player = a.player, coords = a.coords, progress = a.progress }
end

function M.accept(id, player, repair)
  local q = by_id[id]
  if not q then return nil, "нет такого задания" end
  if state.quests.done[id] then return nil, "задание уже выполнено" end
  if q.min_repair > (repair or 0) then return nil, "задание пока недоступно" end
  if state.quests.active then return nil, "уже есть активное задание: " .. state.quests.active.id end
  if not valid(player) then player = player_fn and player_fn() end
  if not valid(player) then
    return nil, "не понял, кто берёт поручение: встаньте у терминала или выберите себя щелчком по имени в строке ввода"
  end
  local a = { id = id, player = player, t = util.now() }
  if q.type == "visit" then
    local r, err = link.call("locate", { target = q.target, player = player, free = true }, 20)
    if not r then return nil, err end
    a.coords = { x = r.x, z = r.z, dim = r.dim }
  elseif q.type == "kill" then
    local r, err = link.call("kill_track", { entity = q.target, player = player })
    if not r then return nil, err end
    a.base = r.count or 0
  end
  state.quests.active = a
  return M.active()
end

function M.abandon()
  state.quests.active = nil
  return true
end

-- Ошибки модуля, после которых повторять выдачу бессмысленно.
local FINAL = { ["награда за это поручение уже выдана"] = true, ["нет такой награды"] = true, ["ошибка таблицы наград"] = true }

-- Выполненные до очереди наград задания: модуль помнит, за что награда выдана, остальное — в очередь. Один раз.
local function recover()
  if state.quests.recovered then return end
  local r = link.call("rewarded", {})
  if not r then return end            -- модуль недоступен: спросим в следующий раз
  local skip = {}
  for _, id in ipairs(r.quests or {}) do skip[id] = true end
  for _, e in ipairs(state.quests.unpaid) do skip[e.id] = true end
  for id in pairs(state.quests.done) do
    if not skip[id] then state.quests.unpaid[#state.quests.unpaid + 1] = { id = id } end
  end
  state.quests.recovered = true
end

-- Выдать награды из очереди. Возвращает строки для ленты.
local function pay(out)
  local u = state.quests.unpaid
  local i = 1
  while u[i] do
    local e = u[i]
    local q = by_id[e.id]
    local player = valid(e.player) and e.player or (player_fn and player_fn())
    if not q or not q.reward or q.reward == "" then
      table.remove(u, i)
    elseif not valid(player) then
      i = i + 1                         -- пока непонятно кому: ждём игрока у терминала
    else
      local r, err = link.call("reward", { reward = q.reward, player = player, quest = e.id })
      if r then
        table.remove(u, i)
        out[#out + 1] = string.format("Награда за «%s» выдана %s: %s.", q.title, player, r.desc or q.reward)
      elseif FINAL[err] then
        table.remove(u, i)
      else
        if not e.told then
          out[#out + 1] = string.format("Награду за «%s» выдам позже (%s).", q.title, tostring(err))
          e.told = true
        end
        i = i + 1
      end
    end
  end
end

-- Проверка выполнения и выдача наград (вызывается периодически). Возвращает текст для чата или nil.
function M.tick()
  local out = {}
  recover()
  local a = state.quests.active
  local q = a and by_id[a.id]
  if a and not q then state.quests.active, a = nil, nil end
  if a and not valid(a.player) and player_fn then a.player = player_fn() or a.player end
  local done = false
  if not a then
    -- нечего проверять
  elseif q.type == "deliver" then
    local cargo, cargo_name = cargo_fn()
    local okl, items = false, nil
    if cargo then okl, items = pcall(cargo.list) end
    if okl and type(items) == "table" then
      -- a.paid — уже списано в ядро (перенос мог прерваться на середине: эти вещи не теряются)
      local have, slots = a.paid or 0, {}
      for slot, it in pairs(items) do
        if it.name == q.target then have = have + it.count; slots[#slots + 1] = slot end
      end
      a.progress = have .. "/" .. q.count
      if have >= q.count then
        local core, why = core_name_fn(cargo_name)
        if not core then
          a.progress = a.progress .. " — не могу забрать"
          if not a.told_reach then
            a.told_reach = true
            out[#out + 1] = string.format("Для «%s» всё собрано, но забрать не могу — %s", q.title, why or "нет ядра")
          end
        else
          a.told_reach = nil
          for _, slot in ipairs(slots) do
            if (a.paid or 0) >= q.count then break end
            -- списываем в утилизатор ядра (инвентарь kubejs:ai_core очищается его тиком)
            local okp, moved = pcall(cargo.pushItems, core, slot, q.count - (a.paid or 0))
            if not okp then util.log("W", "quests: %s -> %s: %s", tostring(cargo_name), core, tostring(moved)); break end
            a.paid = (a.paid or 0) + (tonumber(moved) or 0)
          end
          done = (a.paid or 0) >= q.count
        end
      end
    end
  elseif q.type == "visit" then
    local r = link.call("pos", { player = a.player })
    if r and a.coords and r.dim == a.coords.dim then
      local dx, dz = r.x - a.coords.x, r.z - a.coords.z
      local dist = math.sqrt(dx * dx + dz * dz)
      a.progress = string.format("%d блоков до цели", dist)
      done = dist <= 48
    end
  elseif q.type == "kill" then
    local r = link.call("kill_count", { entity = q.target, player = a.player })
    if r then
      local n = (r.count or 0) - (a.base or 0)
      a.progress = n .. "/" .. q.count
      done = n >= q.count
    end
  end
  if done then
    state.quests.done[a.id] = true
    state.quests.active = nil
    state.quests.unpaid[#state.quests.unpaid + 1] = { id = a.id, player = a.player }
    out[#out + 1] = string.format("Задание «%s» выполнено.", q.title)
  end
  pay(out)
  return #out > 0 and table.concat(out, " ") or nil
end

return M
