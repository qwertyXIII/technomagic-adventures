Проверенный пример (офлайн-тест на модели мира). Черепашка с киркой выкапывает прямоугольник WIDTH × LENGTH слой за слоем вниз на DEPTH слоёв, начиная со своего уровня. Подготовка: черепашка в углу будущего карьера смотрит вдоль длины, карьер — вперёд и вправо от неё; сундук сразу ПОЗАДИ; уголь — в любой слот. Возвращается при полном инвентаре или нехватке топлива, оставляет себе одну стопку топлива. Прогресс в файле: после перезагрузки (с «tmexec startup») сначала едет домой, затем продолжает с текущего слоя. Бедрок — штатное завершение.

```lua
-- ===== настройки =====
local WIDTH, LENGTH, DEPTH = 8, 8, 16   -- вправо, вперёд, вниз (слоёв)
local STATE = "/mine_state.txt"         -- файл прогресса
local RESERVE = 20                      -- запас топлива сверх дороги домой

-- позиция от старта: x вправо, z вперёд, y вверх; dir 0 вперёд, 1 вправо, 2 назад, 3 влево
local pos = { x = 0, y = 0, z = 0, dir = 0, layer = 0 }
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local function save()
  local h = fs.open(STATE, "w"); h.write(textutils.serialize(pos)); h.close()
end
local function loadState()
  if not fs.exists(STATE) then return false end
  local h = fs.open(STATE, "r"); local t = textutils.unserialize(h.readAll()); h.close()
  if type(t) ~= "table" then return false end
  pos = t
  return true
end

local function turnRight() turtle.turnRight(); pos.dir = (pos.dir + 1) % 4; save() end
local function turnLeft() turtle.turnLeft(); pos.dir = (pos.dir + 3) % 4; save() end
local function face(d)
  if (pos.dir + 3) % 4 == d then turnLeft() end
  while pos.dir ~= d do turnRight() end
end

-- шаг с копанием; false, причина — если пройти нельзя (бедрок, приват, нет топлива)
local function step(move, dig, detect, attack)
  for _ = 1, 40 do
    local ok, why = move()
    if ok then return true end
    if why == "Out of fuel" then return false, why end
    if detect() then
      local dug, err = dig()
      if not dug and err ~= "Nothing to dig here" then return false, err end
    else
      attack()
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

-- путь: вверх, по x, по z, вниз — всё внутри уже выкопанного
local function goTo(x, y, z)
  while pos.y < y do assert(up()) end
  if pos.x ~= x then face(x > pos.x and 1 or 3) end
  while pos.x ~= x do assert(fwd()) end
  if pos.z ~= z then face(z > pos.z and 0 or 2) end
  while pos.z ~= z do assert(fwd()) end
  while pos.y > y do assert(down()) end
end

local function distHome() return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z) end

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

local function full()
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then return false end end
  return true
end

-- дома: лицом к сундуку, выгрузить всё, кроме одной стопки топлива
local function unload()
  face(2)                                 -- развернулись: сундук теперь ПЕРЕД черепашкой ("front")
  if not peripheral.hasType("front", "inventory") then error("No chest behind the start point", 0) end
  local kept = false
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if not kept and turtle.refuel(0) then kept = true
      elseif not turtle.drop() then error("Chest is full", 0) end
    end
  end
  turtle.select(1)
end

-- съездить домой (выгрузка/топливо) и вернуться в ту же точку
local function serviceTrip()
  local bx, by, bz, bd = pos.x, pos.y, pos.z, pos.dir
  goTo(0, 0, 0)
  unload()
  local need = 2 * (math.abs(bx) + math.abs(by) + math.abs(bz)) + RESERVE * 2
  while not refuel(need) do
    print("Need fuel: put coal into the turtle")
    os.pullEvent("turtle_inventory")
  end
  goTo(bx, by, bz)
  face(bd)
end

-- один слой змейкой; false — упёрлись в бедрок/приват
local function mineLayer(y)
  for x = 0, WIDTH - 1 do
    local z1, z2, dz = 0, LENGTH - 1, 1
    if x % 2 == 1 then z1, z2, dz = LENGTH - 1, 0, -1 end
    for z = z1, z2, dz do
      if full() or not refuel(distHome() + RESERVE) then serviceTrip() end
      local ok, err = true, nil
      if pos.y > y then ok, err = down() end            -- спуск на новый слой в углу
      if ok and pos.x ~= x then face(x > pos.x and 1 or 3); ok, err = fwd()
      elseif ok and pos.z ~= z then face(z > pos.z and 0 or 2); ok, err = fwd() end
      if not ok then print("Stop: " .. tostring(err)); return false end
    end
  end
  return true
end

-- ===== основная программа =====
if not turtle then error("This program needs a turtle", 0) end
if loadState() then
  print("Resuming at layer " .. pos.layer)
  goTo(0, 0, 0)
  unload()
end
if not refuel(RESERVE * 2) then error("No fuel: put coal into the turtle", 0) end

for layer = pos.layer, DEPTH - 1 do
  pos.layer = layer; save()
  print("Layer " .. (layer + 1) .. "/" .. DEPTH)
  goTo(0, math.min(pos.y, -layer + 1), 0)   -- на угол слоя по прокопанному
  if not mineLayer(-layer) then break end
end

goTo(0, 0, 0)
unload()
face(0)
fs.delete(STATE)
print("Quarry finished")
```

ПОЯСНЕНИЯ
- Защита зоны: черепашка двигается только внутри прямоугольника и над ним; переход на новый слой — из угла (0, 0).
- Остановка игроком («стоп») сохраняет файл: повторный запуск продолжит. Чтобы начать заново — удалить /mine_state.txt.
- Для работы вдали от игроков нужен контроллер чанков AP на черепашке или прогрузка чанков FTB Chunks.
