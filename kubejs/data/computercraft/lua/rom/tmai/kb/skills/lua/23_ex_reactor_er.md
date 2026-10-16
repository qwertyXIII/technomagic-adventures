Проверенный пример (офлайн-тест с моделью реактора). Компьютер вплотную к компьютерному порту усиленного реактора (или проводной модем на порту). Реактор с пассивным охлаждением (выдаёт FE). Логика: при перегреве — выключить и вставить стержни полностью, заблокировать до остывания; буфер ≥ 90 % — выключить, ≤ 30 % — включить; в работе стержни ставятся по заполнению буфера. Монитор и чат-коробка — по желанию.

```lua
-- ===== настройки =====
local MAX_FUEL_TEMP = 1800     -- °C: выше — аварийное отключение
local MAX_CASING_TEMP = 1500   -- °C
local RESUME_TEMP = 800        -- °C: после аварии — снова можно включать
local OFF_AT, ON_AT = 0.90, 0.30   -- доля заполнения буфера: выключить / включить
local ROD_CONTROL = true       -- плавно двигать стержни по заполнению буфера
local AUTO_RESTART = true      -- включать снова после остывания (false — только вручную)
local PERIOD = 1               -- сек между проверками

local reactor = peripheral.find("BigReactors-Reactor") or error("No Extreme Reactors computer port found", 0)
local mon = peripheral.find("monitor")          -- необязательно
local box = peripheral.find("chat_box")         -- необязательно

local lastMsg = 0
local function alert(text)
  print(text)
  if box and os.clock() - lastMsg > 2 then
    pcall(box.sendMessage, text, { utf8 = true, prefix = "Reactor" })
    lastMsg = os.clock()
  end
end

-- безопасный вызов метода реактора
local function call(name, ...)
  local ok, v = pcall(reactor[name], ...)
  if ok then return v end
  return nil
end

local function show(lines)
  if not mon then return end
  mon.setTextScale(1); mon.setBackgroundColor(colors.black); mon.clear()
  for i, l in ipairs(lines) do
    mon.setCursorPos(1, i)
    mon.setTextColor(l.color or colors.white)
    mon.write(l.text)
  end
end

local locked = false            -- авария: ждём остывания
while true do
  if not call("mbIsAssembled") then
    show({ { text = "Reactor not assembled", color = colors.red } })
  else
    local fuelT = call("getFuelTemperature") or 0
    local caseT = call("getCasingTemperature") or 0
    local stored = call("getEnergyStored") or 0
    local cap = math.max(1, call("getEnergyCapacity") or 1)
    local fill = stored / cap
    local active = call("getActive")

    if fuelT > MAX_FUEL_TEMP or caseT > MAX_CASING_TEMP then
      if active or not locked then
        call("setActive", false)
        call("setAllControlRodLevels", 100)
        alert(("REACTOR SCRAM: fuel %.0fC casing %.0fC"):format(fuelT, caseT))
      end
      locked = true
    elseif locked then
      if fuelT < RESUME_TEMP and caseT < RESUME_TEMP and AUTO_RESTART then
        locked = false
        alert("Reactor cooled down, automatic control resumed")
      end
    else
      if active and fill >= OFF_AT then
        call("setActive", false)
      elseif not active and fill <= ON_AT then
        call("setActive", true)
      end
      if ROD_CONTROL then
        call("setAllControlRodLevels", math.floor(fill * 100))
      end
    end

    show({
      { text = "Reactor " .. (locked and "LOCKED" or (call("getActive") and "ON" or "OFF")),
        color = locked and colors.red or colors.lime },
      { text = ("Fuel  %5.0f C"):format(fuelT) },
      { text = ("Case  %5.0f C"):format(caseT) },
      { text = ("Buffer %5.1f %%"):format(fill * 100), color = fill > OFF_AT and colors.orange or colors.white },
      { text = ("Out %d FE/t"):format(math.floor(call("getEnergyProducedLastTick") or 0)) },
    })
  end
  sleep(PERIOD)
end
```

ПОЯСНЕНИЯ
- Пороговые температуры подбери под свой реактор: посмотри рабочие значения в GUI при нормальной нагрузке и поставь порог на 20–30 % выше.
- Реактор с активным охлаждением (пар для турбин) энергию не копит: вместо буфера следи за getHotFluidStats() и турбиной (lua.er).
- AUTO_RESTART = false — после аварии реактор включает только игрок (перезапуском программы).
- Остановка программы («стоп») реактор не выключает — он останется в последнем состоянии.
