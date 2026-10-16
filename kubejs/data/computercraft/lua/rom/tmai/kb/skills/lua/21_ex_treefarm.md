Проверенный пример (офлайн-тест на модели мира). Черепашка с киркой или топором стоит на земле лицом к месту дерева (перед ней земля/дёрн с саженцем или пусто), сундук — сразу ПОЗАДИ. Саженцы и при желании костная мука — в инвентаре. Деревья 1×1 (берёза, ель, джунгли, обычный дуб). Цикл: выросло → срубить ствол вверх, спуститься, собрать упавшее перед собой, посадить новый саженец, сдать брёвна; не выросло — удобрить (если есть мука) или ждать.

```lua
-- ===== настройки =====
local CHECK_EVERY = 15        -- сек между проверками саженца
local MAX_HEIGHT = 32         -- выше не рубим (защита от бесконечного подъёма)
local USE_BONEMEAL = true     -- удобрять саженец костной мукой, если она есть
local MIN_FUEL = 200          -- ниже — дозаправка брёвнами/углём из инвентаря

local function hasTag(detail, tag) return detail and detail.tags and detail.tags[tag] end

-- найти слот с предметом по тегу или id (подробная информация — с тегами)
local function findSlot(test)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s, true)
    if d and test(d) then return s, d end
  end
end
local function isSapling(d) return hasTag(d, "minecraft:saplings") or d.name:find("sapling") ~= nil end
local function isLog(d) return hasTag(d, "minecraft:logs") end
local function isBonemeal(d) return d.name == "minecraft:bone_meal" end

local function refuel()
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" or lvl >= MIN_FUEL then return end
  for pass = 1, 2 do                  -- 1-й проход: уголь и прочее топливо, 2-й: брёвна
    for s = 1, 16 do
      local d = turtle.getItemDetail(s, true)
      local log = d and isLog(d) and true or false
      if d and not isSapling(d) and log == (pass == 2) then
        turtle.select(s)
        while turtle.getFuelLevel() < MIN_FUEL and turtle.refuel(1) do end
      end
    end
  end
  turtle.select(1)
  if turtle.getFuelLevel() < 20 then error("Out of fuel: give the turtle coal or logs", 0) end
end

-- впереди бревно?
local function logAhead(inspect)
  local ok, block = (inspect or turtle.inspect)()
  return ok and block.tags and block.tags["minecraft:logs"]
end

-- срубить ствол: шаг вперёд, вверх по брёвнам, обратно вниз и назад
local function chop()
  turtle.dig()
  if not turtle.forward() then return end   -- не прошли (моб) — в следующий раз
  local h = 0
  while h < MAX_HEIGHT and logAhead(turtle.inspectUp) do
    turtle.digUp()
    if not turtle.up() then break end
    h = h + 1
  end
  while h > 0 do
    if turtle.down() then h = h - 1
    else turtle.digDown(); turtle.attackDown(); sleep(0.2) end
  end
  if not turtle.back() then                 -- позади что-то мешает: развернуться и пройти
    turtle.turnRight(); turtle.turnRight(); turtle.dig(); turtle.forward()
    turtle.turnRight(); turtle.turnRight()
  end
end

local function plant()
  local s = findSlot(isSapling)
  if not s then return false end
  turtle.select(s)
  local ok = turtle.place()
  turtle.select(1)
  return ok
end

-- сдать в сундук позади всё, кроме саженцев, муки и одной стопки брёвен на топливо
local function deposit()
  turtle.turnRight(); turtle.turnRight()
  if not peripheral.hasType("front", "inventory") then
    turtle.turnRight(); turtle.turnRight()
    error("No chest behind the turtle", 0)
  end
  local keptLogs = false
  for s = 1, 16 do
    local d = turtle.getItemDetail(s, true)
    if d and not isSapling(d) and not isBonemeal(d) then
      if isLog(d) and not keptLogs then keptLogs = true
      else
        turtle.select(s)
        if not turtle.drop() then print("Chest is full") end
      end
    end
  end
  turtle.select(1)
  turtle.turnRight(); turtle.turnRight()
end

-- ===== основной цикл =====
if not turtle then error("This program needs a turtle", 0) end
local harvested = 0
while true do
  refuel()
  if logAhead() then
    chop()
    for _ = 1, 4 do turtle.suck() end      -- подобрать упавшее прямо перед собой
    plant()
    deposit()
    harvested = harvested + 1
    print("Trees harvested: " .. harvested)
  else
    local ok, block = turtle.inspect()
    if not ok then
      if not plant() then                   -- пусто: сажаем; саженцев нет — ждём игрока
        print("No saplings: waiting for them in the inventory")
        os.pullEvent("turtle_inventory")
      end
    elseif USE_BONEMEAL and block.name:find("sapling") then
      local s = findSlot(isBonemeal)
      if s then turtle.select(s); turtle.place(); turtle.select(1) end
    end
    sleep(CHECK_EVERY)
  end
end
```

ПОЯСНЕНИЯ
- Черепашка рубит только ствол прямо перед собой и выше; листву не трогает (опавшие саженцы соберёт, только если упадут перед ней — лучше поставить воронку или вакуумный сборщик).
- Широкие деревья 2×2 (тёмный дуб, ель 2×2) эта программа не срубит целиком.
- Топливо — уголь в инвентаре или собственные брёвна (одна стопка остаётся на топливо).
