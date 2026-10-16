-- tmai.me — МЭ-сеть AE2 через ME Bridge (Advanced Peripherals 0.8.x, тип "me_bridge").
-- Методы (из jar): isConnected, isOnline, getItems([filter]), getItem(filter),
--   getCraftableItems([filter]), isCraftable(filter), craftItem(filter[, cpu]) -> job,
--   getCraftingTasks(), getCraftingCPUs(), cancelCraftingTasks(filter),
--   getStoredEnergy, getEnergyUsage, getUsedItemStorage, getMaxItemStorage ...
-- filter = { name = "minecraft:iron_ingot", count = N, components = ... }
-- job (объект): getId, isDone, isCanceled, isCalculationNotSuccessful, hasErrorOccurred,
--   getDebugMessage, getMissingItems, getItemProgress, getTotalItems, cancel
-- Событие по ходу крафта: "ae_crafting", isError, jobId, status

local u8 = require("tmai.u8")
local util = require("tmai.util")

local M = {}

local bridge
local pending = {}      -- code -> { item, count, player, expires }
local jobs = {}         -- id -> { job, item, count, player, started }

function M.attach()
  bridge = peripheral.find("me_bridge")
  return bridge ~= nil
end

local function online()
  if not bridge then M.attach() end
  if not bridge then return false, "ME Bridge не подключён к компьютеру капсулы" end
  local ok, on = pcall(bridge.isOnline)
  if not ok or not on then return false, "МЭ-сеть не отвечает (нет питания или канала)" end
  return true
end

function M.status()
  local ok, err = online()
  if not ok then return { connected = false, error = err } end
  local function n(f) local o, v = pcall(f); return o and v or nil end
  return {
    connected = true,
    item_storage_used = n(bridge.getUsedItemStorage),
    item_storage_max = n(bridge.getMaxItemStorage),
    energy_stored = n(bridge.getStoredEnergy),
    energy_usage = n(bridge.getEnergyUsage),
    crafting_cpus = (function() local o, v = pcall(bridge.getCraftingCPUs); return o and type(v) == "table" and #v or 0 end)(),
  }
end

-- Поиск предметов по подстроке в ID или отображаемом имени (имя — на языке сервера/хоста).
local function match_list(list, query, limit)
  local q = u8.lower(u8.trim(query or ""))
  local out = {}
  for i, it in ipairs(list or {}) do
    local name = it.name or ""
    local dn = it.displayName or ""
    if q == "" or u8.lower(name):find(q, 1, true) or u8.lower(dn):find(q, 1, true) then
      out[#out + 1] = { id = name, name = dn, count = it.count or it.amount, craftable = it.isCraftable }
      if #out >= limit then break end
    end
    if i % 500 == 0 then util.yield() end
  end
  return out
end

function M.find(query, limit)
  local ok, err = online(); if not ok then return nil, err end
  local pok, items = pcall(bridge.getItems)
  if not pok then return nil, tostring(items) end
  return match_list(items, query, limit or 15)
end

function M.find_craftable(query, limit)
  local ok, err = online(); if not ok then return nil, err end
  local pok, items = pcall(bridge.getCraftableItems)
  if not pok then return nil, tostring(items) end
  return match_list(items, query, limit or 15)
end

local function valid_id(id) return type(id) == "string" and id:match("^[a-z0-9_%.%-]+:[a-z0-9_/%.%-]+$") ~= nil end

local function start_craft(item, count, player)
  local ok, err = online(); if not ok then return nil, err end
  local pok, craftable = pcall(bridge.isCraftable, { name = item })
  if not pok or not craftable then return nil, "нет шаблона автокрафта для " .. item end
  local cok, job, jerr = pcall(bridge.craftItem, { name = item, count = count })
  if not cok then return nil, tostring(job) end
  if not job then return nil, tostring(jerr or "МЭ отказала в заказе") end
  local id = (type(job) == "table" and job.getId) and job.getId() or tostring(os.epoch("utc"))
  jobs[id] = { job = job, item = item, count = count, player = player, started = util.now() }
  util.log("I", "craft started %s x%d for %s (job %s)", item, count, tostring(player), tostring(id))
  return { status = "started", job_id = id, item = item, count = count }
end

-- Заказ от нейросети: мелкое — сразу; крупное — код подтверждения, исполняет программа сама
-- по сообщению игрока «да КОД» (нейросеть не может подтвердить за игрока).
function M.request_craft(item, count, player, cfg)
  if not valid_id(item) then return nil, "неверный ID предмета" end
  count = math.floor(tonumber(count) or 0)
  if count < 1 or count > 100000 then return nil, "количество вне диапазона 1..100000" end
  if count > cfg.craft_confirm_over or cfg.confirm_items[item] then
    local code = string.format("%03d", math.random(100, 999))
    pending[code] = { item = item, count = count, player = player, expires = util.now() + 120 }
    return { status = "needs_confirmation", code = code,
      say = "Крупный заказ. Игрок должен написать в чат: «да " .. code .. "» в течение 2 минут." }
  end
  return start_craft(item, count, player)
end

-- Вызывается из обработчика чата (минуя нейросеть).
function M.confirm(code, player)
  local p = pending[code]
  if not p then return nil, "нет заказа с таким кодом" end
  pending[code] = nil
  if util.now() > p.expires then return nil, "код подтверждения истёк" end
  return start_craft(p.item, p.count, player)
end

function M.jobs_summary()
  local out = {}
  for id, j in pairs(jobs) do
    local st = "в работе"
    local ok, done = pcall(j.job.isDone)
    if ok and done then st = "готово" end
    local ok2, fail = pcall(j.job.isCalculationNotSuccessful)
    if ok2 and fail then
      st = "не хватает ресурсов"
      local ok3, missing = pcall(j.job.getMissingItems)
      if ok3 and type(missing) == "table" then
        local names = {}
        for _, m in ipairs(missing) do
          names[#names + 1] = (m.name or "?") .. " x" .. tostring(m.count or m.amount or "?")
          if #names >= 6 then break end
        end
        st = st .. ": " .. table.concat(names, ", ")
      end
    end
    out[#out + 1] = { job_id = id, item = j.item, count = j.count, state = st }
  end
  return out
end

-- Обработка события ae_crafting: вернуть текст для чата или nil.
function M.on_event(is_error, job_id, status)
  local j = jobs[job_id] or jobs[tostring(job_id)]
  if not j then return nil end
  if is_error then
    jobs[job_id] = nil
    return string.format("Заказ %s x%d: ошибка (%s).", j.item, j.count, tostring(status))
  end
  if tostring(status):upper():find("DONE") or tostring(status):upper():find("FINISH") then
    jobs[job_id] = nil
    return string.format("Заказ %s x%d выполнен.", j.item, j.count)
  end
  return nil
end

return M
