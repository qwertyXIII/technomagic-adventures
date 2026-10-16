Проверенный пример (офлайн-тест с модельными сундуками). Компьютер, проводной модем на каждом сундуке/бочке и на компьютере, всё соединено кабелем (модемы включены ПКМ — в чат пишется имя "minecraft:chest_N"). Из входного сундука каждый предмет уходит в сундук по первому подходящему правилу, иначе — в сундук «прочее». При запуске программа печатает все найденные инвентари — по ним игрок или ИИ заполняет правила.

```lua
-- ===== настройки =====
local INPUT = "minecraft:chest_0"          -- входной сундук (сюда кидают всё подряд)
local OVERFLOW = "minecraft:chest_1"       -- куда всё, что не подошло ни под одно правило
-- правило: { что, куда }. Что: "id:предмет" | "#тег" | "@мод" | "~шаблон Lua по id"
local RULES = {
  { "minecraft:cobblestone", "minecraft:chest_2" },
  { "#c:ores",               "minecraft:chest_3" },
  { "#c:ingots",             "minecraft:chest_4" },
  { "@mekanism",             "minecraft:barrel_0" },
  { "~_log$",                "minecraft:chest_5" },
}
local IDLE_SLEEP = 3                       -- пауза, когда входной сундук пуст

-- ===== проверки =====
local input = peripheral.wrap(INPUT) or error("Input inventory not found: " .. INPUT, 0)
local function checkTarget(name)
  if not peripheral.isPresent(name) or not peripheral.hasType(name, "inventory") then
    error("Target inventory not found: " .. name, 0)
  end
end
checkTarget(OVERFLOW)
for _, r in ipairs(RULES) do checkTarget(r[2]) end

print("Inventories on the network:")
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.hasType(n, "inventory") then print("  " .. n) end
end

-- ===== подбор правила =====
local tagCache = {}                         -- id -> теги (getItemDetail дорогой, кэшируем)
local function tagsOf(slot, name)
  if tagCache[name] == nil then
    local d = input.getItemDetail(slot)
    tagCache[name] = (d and d.tags) or {}
  end
  return tagCache[name]
end

local function matches(rule, slot, name)
  local what = rule[1]
  local kind, rest = what:sub(1, 1), what:sub(2)
  if kind == "#" then return tagsOf(slot, name)[rest] == true end
  if kind == "@" then return name:match("^([^:]+):") == rest end
  if kind == "~" then return name:find(rest) ~= nil end
  return name == what
end

local function targetFor(slot, name)
  for _, r in ipairs(RULES) do
    if matches(r, slot, name) then return r[2] end
  end
  return OVERFLOW
end

-- ===== основной цикл =====
local warned = {}
while true do
  local items = input.list()                -- один вызов на проход
  local movedAny = false
  for slot, item in pairs(items) do
    local target = targetFor(slot, item.name)
    local moved = input.pushItems(target, slot)
    if moved == 0 and target ~= OVERFLOW then
      moved = input.pushItems(OVERFLOW, slot)       -- целевой полон — в «прочее»
    end
    if moved > 0 then
      movedAny = true
      warned[item.name] = nil
    elseif not warned[item.name] then
      print("No room for " .. item.name)
      warned[item.name] = true
    end
  end
  if not movedAny then sleep(IDLE_SLEEP) end
end
```

ПОЯСНЕНИЯ
- Все сундуки должны быть в ОДНОЙ проводной сети с компьютером (или вплотную к нему) — иначе pushItems не видит цель.
- Порядок правил важен: первое подходящее выигрывает.
- Теги предметов смотрят в JEI (F3+H) или в выводе getItemDetail(slot).tags; популярные: #c:ores, #c:ingots, #c:gems, #minecraft:logs, #minecraft:saplings.
- Большие склады: вместо сундуков — ME-мост (lua.ap.me), сортировка не нужна.
