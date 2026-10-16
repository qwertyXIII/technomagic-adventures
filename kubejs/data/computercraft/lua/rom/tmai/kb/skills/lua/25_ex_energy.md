Проверенный пример (офлайн-тест с моделями накопителей). Продвинутый монитор (лучше 2×3 блока и больше) и накопители — вплотную к компьютеру или в проводной сети. Программа сама находит индукционные матрицы и энергоячейки Mekanism (джоули → FE), пилоны энергоядра Draconic и любые FE-хранилища ("energy_storage"), рисует полосу каждого, сумму и изменение за секунду. Без мерцания (буфер window).

```lua
-- ===== настройки =====
local TEXT_SCALE = 0.5      -- меньше — больше строк на мониторе
local PERIOD = 1            -- сек между обновлениями
local LOW = 0.15            -- доля: ниже — красная полоса

local mon = peripheral.find("monitor") or error("No monitor found", 0)

local function fe(j)        -- Mekanism отдаёт джоули
  if mekanismEnergyHelper then return mekanismEnergyHelper.joulesToFE(j) end
  return j / 2.5
end

-- источники: { name, label, read = function() return stored, capacity (FE) end }
local function findSources()
  local list = {}
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    local t = peripheral.getType(name)
    local src
    if t == "inductionPort" or (t and t:find("EnergyCube$")) then
      src = function() return fe(p.getEnergy()), fe(p.getMaxEnergy()) end
    elseif t == "draconic_rf_storage" then
      src = function() return p.getEnergyStored(), p.getMaxEnergyStored() end
    elseif peripheral.hasType(name, "energy_storage") then
      src = function() return p.getEnergy(), p.getEnergyCapacity() end
    end
    if src then list[#list + 1] = { name = name, label = (t or name):sub(1, 18), read = src } end
  end
  return list
end

local function short(x)
  local a = math.abs(x)
  if a >= 1e12 then return ("%.2fT"):format(x / 1e12) end
  if a >= 1e9 then return ("%.2fG"):format(x / 1e9) end
  if a >= 1e6 then return ("%.2fM"):format(x / 1e6) end
  if a >= 1e3 then return ("%.1fk"):format(x / 1e3) end
  return ("%d"):format(math.floor(x))
end

mon.setTextScale(TEXT_SCALE)
local w, h = mon.getSize()
local win = window.create(mon, 1, 1, w, h, false)

local function bar(y, frac)
  local width = w - 2
  local fill = math.floor(width * math.max(0, math.min(1, frac)) + 0.5)
  win.setCursorPos(2, y)
  win.setBackgroundColor(frac < LOW and colors.red or colors.lime); win.write((" "):rep(fill))
  win.setBackgroundColor(colors.gray); win.write((" "):rep(width - fill))
  win.setBackgroundColor(colors.black)
end

local sources = findSources()
if #sources == 0 then error("No energy storages found (wired modem enabled?)", 0) end
print("Energy sources: " .. #sources)

local prevTotal, prevTime
while true do
  win.setVisible(false)
  win.setBackgroundColor(colors.black); win.clear()
  local total, totalCap, y = 0, 0, 1
  for _, s in ipairs(sources) do
    local ok, stored, cap = pcall(s.read)
    if ok and stored and cap and cap > 0 then
      total, totalCap = total + stored, totalCap + cap
      if y + 1 <= h - 3 then
        win.setTextColor(colors.white); win.setCursorPos(1, y)
        win.write(("%s %s/%s"):format(s.label, short(stored), short(cap)))
        bar(y + 1, stored / cap)
        y = y + 2
      end
    end
  end
  -- сумма и скорость изменения
  local now = os.clock()
  local rate = 0
  if prevTotal and now > prevTime then rate = (total - prevTotal) / (now - prevTime) / 20 end -- FE/t
  prevTotal, prevTime = total, now
  win.setCursorPos(1, h - 2); win.setTextColor(colors.yellow)
  win.write(("Total %s / %s FE"):format(short(total), short(totalCap)))
  if totalCap > 0 then bar(h - 1, total / totalCap) end
  win.setCursorPos(1, h); win.setTextColor(rate >= 0 and colors.lime or colors.red)
  win.write(("%s%s FE/t"):format(rate >= 0 and "+" or "", short(rate)))
  win.setVisible(true)
  sleep(PERIOD)
end
```

ПОЯСНЕНИЯ
- Новые накопители подхватываются только при перезапуске программы (можно добавить обработку события peripheral).
- У индукционной матрицы подключай к сети один порт: каждый порт — отдельная периферия, иначе энергия посчитается дважды.
- Если пусто — проверь, что проводные модемы на накопителях включены (ПКМ) и компьютер в той же сети.
- Изменение считается по сумме: «+» — копится, «−» — расходуется.
