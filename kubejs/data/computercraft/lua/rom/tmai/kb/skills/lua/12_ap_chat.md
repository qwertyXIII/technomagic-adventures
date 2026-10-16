Сверено с AdvancedPeripherals-1.21.1-0.8.2a.jar. Ошибки AP: методы возвращают nil, "ТЕКСТ" (не бросают) — проверяй.

ЧАТ-КОРОБКА (тип "chat_box"; есть и апгрейд черепашки/КПК)
- sendMessage(текст[, опции]) → true | nil, ошибка. Опции: { utf8 = true (обязательно для кириллицы), player = "Ник" (лично), range = блоков, prefix = "Farm" (в скобках), brackets = "[]", bracketsColor = "&b" }.
- sendFormattedMessage(json_компонент[, опции]) — текст в формате JSON text component (цвета, клики): textutils.serializeJSON({ text = "ALARM", color = "red" }).
- sendToast({ title = "...", message = "...", player = "Ник", utf8 = true[, prefix, brackets, bracketsColor] }) — всплывающее окно игроку (player обязателен). sendFormattedToast — то же с JSON.
- narrateMessage(текст[, { player =, utf8 =, delay = }]) — озвучка экранным диктором.
- Кулдаун 1 с на сообщение с одной коробки: шли не чаще; при ошибке — sleep(1.1) и повтор.
- Длина ~до 1000 байт; кириллица 2 байта на букву.
- Событие chat(uuid, ник, текст, скрыто, текст_utf8): для кириллицы бери 5-й аргумент (3-й придёт как «????»). Сообщение игрока, начинающееся с $, не показывается в общем чате (скрыто = true).
- В сборке своя чат-коробка у ЛОЦМАНа в капсуле — твоя программа на другом компьютере ставит свою.

```lua
local box = peripheral.find("chat_box") or error("No chat box", 0)
local function say(text, player)
  for _ = 1, 5 do
    local ok, err = box.sendMessage(text, { utf8 = true, prefix = "Farm", player = player })
    if ok then return true end
    sleep(1.1)                        -- кулдаун коробки
  end
  return false
end
```

ДЕТЕКТОР ИГРОКОВ (тип "player_detector"; без карты памяти)
- getOnlinePlayers() → { "Ник", … }.
- getPlayersInRange(радиус) → ники; isPlayersInRange(радиус) → bool; isPlayerInRange(радиус, "Ник").
- getPlayersInCubic(ширина, высота, глубина) / isPlayersInCubic(w, h, d) / isPlayerInCubic(w, h, d, "Ник") — коробка с центром в детекторе.
- getPlayersInCoords({x,y,z}, {x,y,z}) / isPlayersInCoords(a, b) / isPlayerInCoords(a, b, "Ник") — область [a, b) в мировых координатах.
- getPlayer("Ник") → { x, y, z, dimension, health, maxHealth, yaw, pitch, eyeHeight, airSupply, respawnPosition, respawnDimension, uuid, name, … } или nil (игрок не в сети/недоступен).
- getPlayerStat(ник, статистика…) → числа.
- События (без wrap, достаточно подключения): player_join(uuid, ник, измерение), player_leave(uuid, ник, измерение), player_changed_dimension(uuid, ник, из, в), player_click(имя_детектора, uuid, ник) — ПКМ по детектору, player_death(uuid, ник, источник_урона).

```lua
local det = peripheral.find("player_detector") or error("No player detector", 0)
while true do
  local near = det.getPlayersInRange(16)
  redstone.setOutput("front", #near > 0)   -- свет/дверь, пока кто-то рядом
  sleep(1)
end
```

МЕНЕДЖЕР ИНВЕНТАРЯ (тип "inventory_manager"; нужна карта памяти, привязанная к игроку ПКМ, вставленная в блок)
- getOwner() → ник владельца карты; size(); list() → { [слот] = предмет } инвентаря игрока.
- exportItem(куда, фильтр) — ИЗ инвентаря игрока в сундук; importItem(откуда, фильтр) — ИЗ сундука игроку. куда/откуда — сторона блока менеджера с @: "@up", "@down", "@north", "@south", "@east", "@west", "@front", "@back", "@left", "@right", "@top", "@bottom" или имя периферии в сети. Возвращает число перенесённых.
- Фильтр: { name = "minecraft:cobblestone", count = 64, fromSlot = 0, toSlot = 5 } (name с # — тег: "#c:ingots").
- getItemInHand(), getItemInOffHand(), getHandSlot(), getFreeSlot(), getEmptySlots(), isWearing(1–4: 1 — ботинки, 4 — шлем).
- Curios: getCuriosSizes(), listCurios(), exportCuriosItem/importCuriosItem(слот_curios, куда/откуда, фильтр).
- Работает, только когда игрок в сети. Забирать предметы у игрока — только по его просьбе.
