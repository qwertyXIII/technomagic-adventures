Геосканер (advancedperipherals:geo_scanner): блок, улучшение черепашки и улучшение КПК. Тип периферии "geo_scanner".
МЕТОДЫ (AP 0.8.2a; имена — именно эти):
- scanBlocks(radius) -> список { name = "minecraft:deepslate_iron_ore", tags = {…}, x, y, z } — координаты ОТ СКАНЕРА (x — восток, z — юг, y — вверх). radius до 8 — бесплатно; 9..16 — тратит FE (блок/черепашка с энергией), КПК — только до 8. Перезарядка ~2 с: в это время вернёт nil, "…cooldown…" — ждать sleep(2) и повторить; больше 16 — ошибка "Radius is exceed max value".
- chunkAnalyze([тег_или_блок]) -> { ["minecraft:iron_ore"] = 12, … } — сколько чего в ТЕКУЩЕМ чанке (по умолчанию руды).
Руда ли блок: тег "c:ores/<материал>" (или "c:ores"), имя *_ore, ancient_debris. tags может прийти списком или множеством — перебирать pairs и брать строку из ключа или значения.
ОГРАНИЧЕНИЯ: у КПК ОДНО место под улучшение — КПК со сканером без модема (связи нет); для него есть готовая программа tmore (рудоискатель), писать свою для КПК не нужно. У черепашки ДВА места: кирка + сканер (тогда без модема) или кирка + модем. Нужны все три — держать сканер/модем в инвентаре и менять: turtle.select(слот); turtle.equipRight() (снятое ляжет в выбранный слот). Программы ставятся через tmexec по модему: если черепашке нужен сканер, программа сама надевает его после запуска (модем снимается — отчёты в tmexec перестанут идти до обратной замены; так и написать игроку).
ПРИМЕР: ближайшая руда вокруг компьютера/черепашки.
```lua
local geo = peripheral.find("geo_scanner") or error("Нужен геосканер", 0)
local function is_ore(b)
  if b.name:find("_ore$") or b.name == "minecraft:ancient_debris" then return true end
  for k, v in pairs(b.tags or {}) do
    local t = type(k) == "string" and k or v
    if type(t) == "string" and t:find("^c:ores") then return true end
  end
  return false
end
local res, err = geo.scanBlocks(8)
while not res do sleep(2); res, err = geo.scanBlocks(8) end   -- перезарядка
local best, bd
for _, b in ipairs(res) do
  if is_ore(b) then
    local d = b.x * b.x + b.y * b.y + b.z * b.z
    if not bd or d < bd then best, bd = b, d end
  end
end
if best then print(("%s: x%+d y%+d z%+d"):format(best.name, best.x, best.y, best.z)) else print("ore: none") end
```
ШАХТЁР (черепашка: кирка + сканер, топливо в слоте 16): сканировать, идти к ближайшей руде (turtle.forward/up/down с turtle.dig* перед шагом, повороты по относительным x/z с учётом своего направления — направление узнать, шагнув вперёд и сравнив новое сканирование, или держать свой счётчик поворотов от старта), копать всю жилу (соседние блоки той же руды — по новым сканированиям), следить за топливом (turtle.getFuelLevel; вернуться, если осталось меньше пути назад + 20), инвентарь полон — назад к сундуку. Возврат — по сохранённому пути (стек шагов). Никогда не копать вниз под себя у бедрока и в лаву: перед шагом проверять turtle.inspect* (minecraft:lava — обойти).
