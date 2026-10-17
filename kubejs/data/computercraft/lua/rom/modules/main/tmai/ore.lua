-- tmai.ore — распознавание руд из ответа геосканера Advanced Peripherals (scanBlocks): вид руды по тегам
-- (c:ores/<материал>, minecraft:<материал>_ores) или по имени блока (*_ore, ancient_debris), русские названия,
-- группировка по видам и направление до блока по сторонам света (север — -Z, восток — +X).
-- Блок сканера: { name = "minecraft:deepslate_iron_ore", tags = {…} (список или множество), x, y, z (от сканера) }.

local u8 = require("tmai.u8")

local M = {}

-- Русские названия материалов (что не нашлось — показываем id материала).
M.NAMES = {
  iron = "железо", gold = "золото", copper = "медь", coal = "уголь", diamond = "алмаз", emerald = "изумруд",
  lapis = "лазурит", redstone = "редстоун", quartz = "кварц", netherite_scrap = "незерит", ancient_debris = "незерит",
  tin = "олово", lead = "свинец", osmium = "осмий", uranium = "уран", fluorite = "флюорит", zinc = "цинк",
  silver = "серебро", nickel = "никель", aluminum = "алюминий", aluminium = "алюминий", platinum = "платина",
  certus_quartz = "кварц истинный", charged_certus_quartz = "кварц заряж.", sulfur = "сера", apatite = "апатит",
  cinnabar = "киноварь", niter = "селитра", saltpeter = "селитра", ruby = "рубин", sapphire = "сапфир",
  amethyst = "аметист", cobalt = "кобальт", iridium = "иридий", tungsten = "вольфрам", titanium = "титан",
  zircon = "циркон", bauxite = "боксит", desh = "деш", ostrum = "острум", calorite = "калорит", ice_shard = "лёд",
  cheese = "сыр", gravitite = "гравитит", ambrosium = "амброзий", zanite = "занит", skyjade = "небесный нефрит",
  moonstone = "лунный камень", mithril = "мифрил", arcane_crystal = "кристалл", source_gem = "самоцвет",
  dimensional_shard = "осколок", nether_gold = "золото", glowstone = "светокамень", salt = "соль",
}

local function tag_list(tags)
  local out = {}
  if type(tags) ~= "table" then return out end
  for k, v in pairs(tags) do
    if type(k) == "string" and v then out[#out + 1] = k
    elseif type(v) == "string" then out[#out + 1] = v end
  end
  return out
end

-- Материал руды или nil (не руда).
function M.material(block)
  if type(block) ~= "table" or type(block.name) ~= "string" then return nil end
  local is_ore = false
  for _, t in ipairs(tag_list(block.tags)) do
    local m = t:match("^c:ores/([%w_]+)$") or t:match("^forge:ores/([%w_]+)$")
    if m then return m end
    if t == "c:ores" or t == "forge:ores" then is_ore = true end
    local v = t:match("^minecraft:([%w_]+)_ores$")
    if v then return v end
  end
  local path = block.name:match(":([%w_/]+)$") or block.name
  if path == "ancient_debris" then return "netherite_scrap" end
  if not is_ore and not path:match("_ore$") and not path:match("^ore_") then return nil end
  local m = path:gsub("^deepslate_", ""):gsub("^nether_", ""):gsub("^end_", ""):gsub("^stone_", "")
  m = m:gsub("_ore$", ""):gsub("^ore_", "")
  for _, pre in ipairs({ "moon_", "mars_", "venus_", "mercury_", "glacio_", "raw_", "dense_", "poor_" }) do
    if m:sub(1, #pre) == pre then m = m:sub(#pre + 1) end
  end
  return m ~= "" and m or path
end

function M.name(material)
  return M.NAMES[material] or (tostring(material):gsub("_", " "))
end

local DIRS = { "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ", "С", "СВ" }
local DIRS_LONG = { "восток", "юго-восток", "юг", "юго-запад", "запад", "северо-запад", "север", "северо-восток" }

-- Сторона света (короткая и полная) от (0,0) к (dx,dz); nil — прямо по вертикали.
function M.compass(dx, dz)
  if dx == 0 and dz == 0 then return nil end
  local atan2 = math.atan2 or math.atan
  local ang = math.deg(atan2(dz, dx))
  local i = (math.floor((ang + 22.5) / 45) % 8) + 1
  return DIRS[i], DIRS_LONG[i]
end

function M.distance(b) return math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z) end

-- «5 СВ -3»: расстояние по горизонтали (по ходу), сторона, высота (+ выше, - ниже).
local function int(v) return math.floor((tonumber(v) or 0) + 0.5) end

function M.where(b)
  local h = int(math.sqrt(b.x * b.x + b.z * b.z))
  local dir = M.compass(b.x, b.z)
  local s = dir and (("%d "):format(h) .. dir) or "тут"
  local y = int(b.y)
  if y > 0 then s = s .. (" +%d"):format(y) elseif y < 0 then s = s .. (" %d"):format(y) end
  return s
end

-- Полностью словами: «5 бл. на северо-восток, на 3 ниже».
function M.where_long(b)
  local h = int(math.sqrt(b.x * b.x + b.z * b.z))
  local _, dir = M.compass(b.x, b.z)
  local parts = {}
  local y = int(b.y)
  parts[#parts + 1] = dir and (("%d бл. на "):format(h) .. dir) or "прямо"
  if y > 0 then parts[#parts + 1] = ("на %d выше"):format(y) elseif y < 0 then parts[#parts + 1] = ("на %d ниже"):format(-y) end
  return table.concat(parts, ", ")
end

-- Руды из ответа сканера по видам: { {material, name, count, blocks = {…по расстоянию}}, … },
-- виды — по ближайшему блоку. filter — часть названия/материала (без учёта регистра латиницы).
function M.group(blocks, filter)
  local by = {}
  for _, b in ipairs(blocks or {}) do
    local m = M.material(b)
    if m and type(b.x) == "number" and type(b.y) == "number" and type(b.z) == "number" then
      local g = by[m]
      if not g then g = { material = m, name = M.name(m), count = 0, blocks = {} }; by[m] = g end
      g.count = g.count + 1
      g.blocks[#g.blocks + 1] = b
    end
  end
  local out = {}
  local f = filter and filter ~= "" and u8.lower(filter) or nil
  for _, g in pairs(by) do
    table.sort(g.blocks, function(a, b) return M.distance(a) < M.distance(b) end)
    if not f or u8.lower(g.name):find(f, 1, true) or g.material:find(f, 1, true) then
      out[#out + 1] = g
    end
  end
  table.sort(out, function(a, b)
    local da, db = M.distance(a.blocks[1]), M.distance(b.blocks[1])
    if da ~= db then return da < db end
    return a.name < b.name
  end)
  return out
end

return M
