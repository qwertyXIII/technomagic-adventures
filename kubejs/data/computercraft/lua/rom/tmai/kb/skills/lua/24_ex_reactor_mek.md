Проверенный пример (офлайн-тест с моделью реактора). Компьютер вплотную к логическому адаптеру или порту реактора деления (или проводной модем). Проверка 4 раза в секунду; при любом опасном показателе — scram() и блокировка. Повторный пуск: только если игрок явно включил AUTO_RESTART, после возврата ВСЕХ показателей в норму и выдержки. Звук (колонка) и чат — по желанию.

```lua
-- ===== настройки (запас до опасных 1200 K) =====
local MAX_TEMP = 1000          -- K: выше — SCRAM (урон реактору начинается с 1200 K)
local MAX_DAMAGE = 0           -- %: любой урон — SCRAM
local MIN_COOLANT = 0.20       -- доля: охлаждающей жидкости меньше — SCRAM
local MAX_HEATED = 0.90        -- доля: нагретый теплоноситель/пар не уходит — SCRAM
local MAX_WASTE = 0.90         -- доля: отходы почти полны — SCRAM
local MIN_FUEL = 0             -- доля: 0 — не проверять топливо
local AUTO_RESTART = false     -- true — сам включает после нормализации (только по просьбе игрока)
local RESTART_DELAY = 30       -- сек норм. показателей перед авто-пуском
local PERIOD = 0.25

local r = peripheral.find("fissionReactorLogicAdapter") or peripheral.find("fissionReactorPort")
  or error("No fission reactor logic adapter or port found", 0)
local box = peripheral.find("chat_box")
local speaker = peripheral.find("speaker")

local function get(name)
  local ok, v = pcall(r[name])
  if ok then return v end
  return nil
end

local function alarm(text)
  print(text)
  if speaker then pcall(speaker.playNote, "bell", 3, 24) end
  if box then pcall(box.sendMessage, text, { utf8 = true, prefix = "Fission" }) end
end

-- причина остановки или nil, если всё в норме
local function danger(s)
  if s.temp >= MAX_TEMP then return ("temperature %.0f K"):format(s.temp) end
  if s.damage > MAX_DAMAGE then return ("damage %.1f%%"):format(s.damage) end
  if s.coolant < MIN_COOLANT then return ("coolant %.0f%%"):format(s.coolant * 100) end
  if s.heated > MAX_HEATED then return ("heated coolant %.0f%%"):format(s.heated * 100) end
  if s.waste > MAX_WASTE then return ("waste %.0f%%"):format(s.waste * 100) end
  if MIN_FUEL > 0 and s.fuel < MIN_FUEL then return ("fuel %.0f%%"):format(s.fuel * 100) end
  return nil
end

local function readState()
  if not get("isFormed") then return nil end
  return {
    on = get("getStatus") == true,
    temp = get("getTemperature") or 0,
    damage = get("getDamagePercent") or 0,
    coolant = get("getCoolantFilledPercentage") or 0,
    heated = get("getHeatedCoolantFilledPercentage") or 0,
    waste = get("getWasteFilledPercentage") or 0,
    fuel = get("getFuelFilledPercentage") or 0,
    burn = get("getActualBurnRate") or 0,
  }
end

local locked, okSince, wasFormed = false, nil, true
local lastLine = ""
while true do
  local s = readState()
  if not s then
    if wasFormed then alarm("Reactor is not formed or not readable") end
    wasFormed = false
  else
    wasFormed = true
    local why = danger(s)
    if why then
      if s.on then
        local ok, err = pcall(r.scram)
        alarm("FISSION SCRAM: " .. why .. (ok and "" or (" (scram error: " .. tostring(err) .. ")")))
      end
      locked, okSince = true, nil
    elseif locked and AUTO_RESTART then
      okSince = okSince or os.clock()
      if os.clock() - okSince >= RESTART_DELAY and not s.on then
        if pcall(r.activate) then alarm("Reactor restarted after cooldown") end
        locked, okSince = false, nil
      end
    end
    local line = ("%s T=%.0fK dmg=%.1f%% cool=%.0f%% hot=%.0f%% waste=%.0f%% burn=%.1f"):format(
      locked and "LOCK" or (s.on and "ON " or "OFF"), s.temp, s.damage,
      s.coolant * 100, s.heated * 100, s.waste * 100, s.burn)
    if line ~= lastLine then
      term.clear(); term.setCursorPos(1, 1); print(line)
      lastLine = line
    end
  end
  sleep(PERIOD)
end
```

ПОЯСНЕНИЯ
- Программа никогда не включает реактор, если AUTO_RESTART = false, — запуск делает игрок кнопкой в GUI.
- Дублирующая защита без компьютера: логический адаптер в режиме "DAMAGED" или "TEMPERATURE" + редстоун (setLogicMode, lua.mekanism.reactors).
- Частая причина перегрева — полная турбина: проверь её буфер и сброс пара (turbineValve: getEnergyFilledPercentage, setDumpingMode("DUMPING_EXCESS")).
- Остановка программы не выключает реактор.
