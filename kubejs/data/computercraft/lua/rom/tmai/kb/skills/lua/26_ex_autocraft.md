Проверенный пример (офлайн-тест с моделью ME-моста). ME-мост в МЭ-сети и у компьютера (вплотную или проводным модемом); в сети есть шаблоны и свободный процессор крафта. Раз в PERIOD секунд программа сравнивает запас с минимумом и, пока запас ниже, заказывает фиксированную порцию, не дублируя уже идущий крафт этого предмета. Результаты приходят событием ae_crafting; опрос и приём событий разнесены по двум корутинам (parallel), чтобы события не терялись во время вызовов моста.

```lua
-- ===== настройки =====
-- { id, минимум, порция заказа }
local KEEP = {
  { "minecraft:iron_ingot", 256, 64 },
  { "minecraft:glass", 128, 64 },
  { "ae2:printed_silicon", 32, 16 },
}
local PERIOD = 20           -- сек между проверками
local MAX_PER_CYCLE = 4     -- не больше заказов за одну проверку

local me = peripheral.find("me_bridge") or error("No ME bridge found", 0)

local jobs = {}             -- id задания -> { item, count }

local function stock(id)
  local it = me.getItem({ name = id })
  return type(it) == "table" and (it.count or 0) or 0
end

local function check()
  for id, j in pairs(jobs) do                -- забыть старые задания (больше часа)
    if os.clock() - j.t > 3600 then jobs[id] = nil end
  end
  if not me.isOnline() then print("ME network offline"); return end
  local orders = 0
  for _, k in ipairs(KEEP) do
    local id, min, batch = k[1], k[2], k[3]
    local have = stock(id)
    if have < min and orders < MAX_PER_CYCLE then
      local filter = { name = id }
      if me.isCrafting(filter) then
        -- уже крафтится — ждём
      elseif not me.isCraftable(filter) then
        print("No pattern for " .. id)
      else
        local n = batch                          -- «заказывать по N»; добрать ровно до минимума: math.min(batch, min - have)
        local job, err = me.craftItem({ name = id, count = n })
        if job then
          jobs[job.getId()] = { item = id, count = n, t = os.clock() }
          orders = orders + 1
          print(("Ordered %d x %s (have %d)"):format(n, id, have))
        else
          print("Craft failed " .. id .. ": " .. tostring(err))
        end
      end
    end
  end
end

local function onCraftEvent(isError, id, msg)
  local j = jobs[id]
  if not j then return end                -- чужое задание (не наше)
  if isError then
    print(("Job %s %s failed: %s"):format(tostring(id), j.item, tostring(msg)))
    jobs[id] = nil
  elseif msg == "CRAFTING_STARTED" then
    print("Crafting started: " .. j.item)
  elseif msg == "JOB_DONE" or msg == "JOB_CANCELED" then
    jobs[id] = nil
  end
end

-- опрос запасов и реакция на события — в разных корутинах (lua.events)
local function poller()
  while true do check(); sleep(PERIOD) end
end
local function listener()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "ae_crafting" or ev == "me_crafting" then onCraftEvent(a, b, c) end
  end
end
parallel.waitForAny(poller, listener)
```

ПОЯСНЕНИЯ
- Минимумы и размер порций — в KEEP; MAX_PER_CYCLE защищает процессоры от завала заказами.
- «No pattern» — в сети нет шаблона: сначала сделать шаблон и поставить в ассемблер.
- Ошибка MISSING_ITEMS — не хватает ресурсов: программа не будет спамить (isCrafting вернёт false, следующий заказ — через PERIOD); подробности — job.getMissingItems().
- Капсула ЛОЦМАНа тоже умеет заказывать крафт по просьбе (инструменты me_*), эта программа — для постоянного поддержания запаса.
