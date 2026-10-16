Черепашка не знает своих координат (без GPS). Ведём их сами от точки старта: x — вправо, z — вперёд, y — вверх; dir 0 вперёд, 1 вправо, 2 назад, 3 влево. Каждый успешный шаг меняет pos и сразу пишется в файл.

```lua
local STATE = "/nav_state.txt"
local pos = { x = 0, y = 0, z = 0, dir = 0 }
local DX = { [0] = 0, 1, 0, -1 }   -- смещение по x для dir
local DZ = { [0] = 1, 0, -1, 0 }   -- смещение по z для dir

local function save()
  local h = fs.open(STATE, "w"); h.write(textutils.serialize(pos)); h.close()
end

local function turnRight() turtle.turnRight(); pos.dir = (pos.dir + 1) % 4; save() end
local function turnLeft()  turtle.turnLeft();  pos.dir = (pos.dir + 3) % 4; save() end
local function face(d)
  if (pos.dir + 3) % 4 == d then turnLeft() end
  while pos.dir ~= d do turnRight() end
end

-- шаг с копанием: гравий, мобы, временные помехи; бедрок и защита — честный отказ
local function step(move, dig, detect, attack)
  for _ = 1, 40 do
    local ok, why = move()
    if ok then return true end
    if why == "Out of fuel" then return false, why end
    if detect() then
      local dug, err = dig()
      if not dug and err ~= "Nothing to dig here" then return false, err end
    else
      attack()                      -- в клетке моб или игрок
    end
    sleep(0.1)
  end
  return false, "Path blocked"
end

local function fwd()
  local ok, err = step(turtle.forward, turtle.dig, turtle.detect, turtle.attack)
  if ok then pos.x = pos.x + DX[pos.dir]; pos.z = pos.z + DZ[pos.dir]; save() end
  return ok, err
end
local function up()
  local ok, err = step(turtle.up, turtle.digUp, turtle.detectUp, turtle.attackUp)
  if ok then pos.y = pos.y + 1; save() end
  return ok, err
end
local function down()
  local ok, err = step(turtle.down, turtle.digDown, turtle.detectDown, turtle.attackDown)
  if ok then pos.y = pos.y - 1; save() end
  return ok, err
end

-- идти в точку: сначала вверх, потом x, z, потом вниз (по уже прокопанному)
local function goTo(tx, ty, tz)
  while pos.y < ty do assert(up()) end
  if pos.x ~= tx then face(tx > pos.x and 1 or 3) end
  while pos.x ~= tx do assert(fwd()) end
  if pos.z ~= tz then face(tz > pos.z and 0 or 2) end
  while pos.z ~= tz do assert(fwd()) end
  while pos.y > ty do assert(down()) end
end

local function distHome() return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z) end

-- дозаправка из инвентаря до need; true, если хватает
local function refuel(need)
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" or lvl >= need then return true end
  for s = 1, 16 do
    turtle.select(s)
    while turtle.getFuelLevel() < need and turtle.refuel(1) do end
  end
  turtle.select(1)
  return turtle.getFuelLevel() >= need
end

local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

-- выгрузка в сундук перед черепашкой; одну стопку топлива оставляем
local function unload()
  if not peripheral.hasType("front", "inventory") then error("No chest in front of home", 0) end
  local keptFuel = false
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if not keptFuel and turtle.refuel(0) then keptFuel = true
      elseif not turtle.drop() then error("Chest is full", 0) end
    end
  end
  turtle.select(1)
end
```

ПРИЁМЫ
- Перед каждым шагом прочь от дома: if not refuel(distHome() + 20) then вернуться и ждать: while not refuel(N) do os.pullEvent("turtle_inventory") end.
- Полный инвентарь: if freeSlots() == 0 then запомнить точку, goTo(0, 0, 0), face(2), unload(), вернуться goTo(точка), face(старое направление).
- assert(…) в goTo превращает отказ («Cannot break unbreakable block») в ошибку с причиной — tmexec сообщит её ИИ. Для бедрока внизу лучше обработать отказ и закончить работу штатно.
- Перезапуск: при старте, если файл состояния есть, загрузи pos (textutils.unserialize) и сначала вернись домой. Позиция может отстать на 1 шаг, если чанк выгрузился посреди движения, — дома проверь сундук (peripheral.hasType("front"/"back", "inventory")) и остановись с ошибкой, если его нет.
- Прогрузка: черепашка работает, только пока её чанк загружен (игрок рядом, FTB Chunks или контроллер чанков AP как апгрейд).
- Не копай вне заданной зоны: все цели goTo — внутри прямоугольника работы и столба над стартом.
