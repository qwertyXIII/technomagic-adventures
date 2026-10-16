Проверенный пример (офлайн-тест). Чат-коробка у компьютера; датчики — по желанию (накопитель энергии, ME-мост, детектор игроков). Каждое условие сообщает один раз при наступлении и один раз при возврате в норму (без спама), сообщения уходят не чаще раза в секунду (кулдаун коробки), кириллица — с utf8. Получатель — один игрок или все.

```lua
-- ===== настройки =====
local PLAYER = nil              -- "Ник" — только ему; nil — всем в радиусе коробки
local PREFIX = "Base"
local CHECK_EVERY = 10          -- сек
local ENERGY_LOW = 0.10         -- доля заряда накопителя
local ME_LOW = { ["minecraft:iron_ingot"] = 64, ["minecraft:coal"] = 32 }  -- id -> минимум
local GREET_PLAYERS = true      -- писать о входе/выходе игроков (нужен детектор игроков)

local box = peripheral.find("chat_box") or error("No chat box found", 0)
local energy = peripheral.find("inductionPort") or peripheral.find("energy_storage")
local me = peripheral.find("me_bridge")

-- очередь сообщений: отправляет отдельная корутина (кулдаун коробки 1 с)
local queue = {}
local function say(text)
  queue[#queue + 1] = text
  os.queueEvent("alert_queued")          -- разбудить отправителя
end

local function sender()
  while true do
    if #queue == 0 then os.pullEvent("alert_queued")
    else
      local ok, err = box.sendMessage(queue[1], { utf8 = true, prefix = PREFIX, player = PLAYER })
      if ok or not tostring(err):lower():find("cooldown") then
        if not ok then print("Chat error: " .. tostring(err)) end
        table.remove(queue, 1)
      end
      sleep(1.1)
    end
  end
end

-- состояние «тревоги» по ключу: сообщаем только при смене
local active = {}
local function condition(key, isBad, badText, okText)
  if isBad and not active[key] then active[key] = true; say(badText)
  elseif not isBad and active[key] then active[key] = nil; if okText then say(okText) end end
end

local function energyFrac()
  if not energy then return nil end
  local ok, cur, max = pcall(function()
    if energy.getEnergyFilledPercentage then return energy.getEnergyFilledPercentage(), 1 end
    return energy.getEnergy(), energy.getEnergyCapacity()
  end)
  if ok and cur and max and max > 0 then return cur / max end
end

-- периодические проверки (вызовы периферии — только здесь)
local function poller()
  while true do
    local f = energyFrac()
    if f then
      condition("energy", f < ENERGY_LOW,
        ("Внимание: энергия базы %.0f%%"):format(f * 100), "Энергия базы восстановлена")
    end
    if me and me.isOnline() then
      for id, min in pairs(ME_LOW) do
        local it = me.getItem({ name = id })
        local n = type(it) == "table" and (it.count or 0) or 0
        condition("me:" .. id, n < min, ("В МЭ мало %s: %d (минимум %d)"):format(id, n, min), nil)
      end
    end
    sleep(CHECK_EVERY)
  end
end

-- реакция на события детектора игроков
local function listener()
  while true do
    local ev, uuid, name = os.pullEvent()
    if GREET_PLAYERS and ev == "player_join" then say(name .. " на связи")
    elseif GREET_PLAYERS and ev == "player_leave" then say(name .. " вышел из игры") end
  end
end

parallel.waitForAny(sender, poller, listener)
```

ПОЯСНЕНИЯ
- Ник латиницей — как в игре; личное сообщение видно только этому игроку.
- Всплывающее окно вместо чата: box.sendToast({ title = "Base", message = "...", player = "Ник", utf8 = true }) — player обязателен.
- События player_join/leave приходят, если к компьютеру подключён детектор игроков (lua.ap.chat).
- Три корутины в parallel: опрос датчиков, приём событий и отправка не мешают друг другу (sleep и вызовы периферии в одной не съедают события другой).
