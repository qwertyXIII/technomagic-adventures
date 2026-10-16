-- tmai.quests — побочные задания ИИ. Нейросеть только ВЫБИРАЕТ задание из заранее
-- заданного списка и озвучивает его; проверку и награду делает программа.
-- /rom/tmai/quests.tsv: id, title, type, target, count, min_repair, reward, hint
--   type = deliver — принести target (ID предмета) x count в грузовой отсек капсулы
--          visit   — дойти до цели разведки target (ID из scout.tsv); координаты даёт TM-NAV
--          kill    — убить count мобов target (ID сущности), счёт ведёт TM-NAV через scoreboard
-- reward — ID награды из rewards.tsv (выдаёт TM-NAV командой /give, один раз на задание).

local util = require("tmai.util")
local link = require("tmai.link")

local M = {}

local list, by_id = {}, {}
local state, cargo_fn, core_name_fn

function M.init(st, get_cargo, get_core_name)
  state = st
  state.quests = state.quests or { done = {}, active = nil }
  cargo_fn, core_name_fn = get_cargo, get_core_name
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

-- Проверка выполнения (вызывается периодически). Возвращает текст для чата или nil.
function M.tick()
  local a = state.quests.active
  if not a then return nil end
  local q = by_id[a.id]
  if not q then state.quests.active = nil; return nil end
  local done = false
  if q.type == "deliver" then
    local cargo = cargo_fn()
    if cargo then
      local have, slots = 0, {}
      for slot, it in pairs(cargo.list()) do
        if it.name == q.target then have = have + it.count; slots[#slots + 1] = slot end
      end
      a.progress = have .. "/" .. q.count
      if have >= q.count then
        local need = q.count
        local core = core_name_fn()
        for _, slot in ipairs(slots) do
          if need <= 0 then break end
          -- списываем в утилизатор ядра (инвентарь kubejs:ai_core очищается его тиком)
          local moved = core and cargo.pushItems(core, slot, need) or 0
          need = need - moved
        end
        done = need <= 0
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
  if not done then return nil end
  state.quests.done[a.id] = true
  state.quests.active = nil
  local r, err = link.call("reward", { reward = q.reward, player = a.player, quest = a.id })
  if r then
    return string.format("Задание «%s» выполнено. Награда выдана: %s.", q.title, r.desc or q.reward)
  end
  return string.format("Задание «%s» выполнено, но выдать награду не удалось (%s).", q.title, tostring(err))
end

return M
