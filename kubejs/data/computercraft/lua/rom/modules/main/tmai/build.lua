-- tmai.build — «прораб»: нейросеть описывает постройку ПЛАНОМ из простых фигур (данные, не код), программа
-- проверяет план, считает смету, рисует его послойно на экране, а после «да КОД» от игрока черепашка-строитель
-- (программа tmbuild, rednet-протокол "tmai_build") строит его из блоков своего сундука-склада.
-- Нейросеть ничего не может сломать: она выдаёт только план; что ставить и что копать, решают проверки здесь
-- и в tmbuild.lua (копает только внутри площадки; землю и камень — только с разрешения clear_site).
--
-- Координаты плана: x — вправо от черепашки, y — вверх, z — вперёд; (0,0,0) — клетка прямо перед черепашкой
-- на её уровне. Черепашка стоит в (0,0,-1) лицом к +z, сундук-склад — позади неё, в (0,0,-2).
-- Номер плана — то, что называет игрок («план 3»); слои для игрока и нейросети считаются с 1 (слой 1 — y=0).
-- Хранилище: /tmai/plans/<N>.json; стройки, выбранный план и склады — /tmai/build_state.json
-- (переживают перезагрузку компьютера ИИ).
--
-- Подключение (app.lua / tools.lua / ui.lua): build.tool_defs(ctx) — в список инструментов, build.run_tool —
-- выполнение, build.on_rednet(sender, msg) — в слушатель (протокол build.PROTO), build.is_job/build.confirm —
-- на «да КОД», build.stop — на «стоп», build.render / build.status_lines — вкладка «Стройка».
-- События интерфейсу: os.queueEvent("tmai_ui", "build", id, layer) — показать план;
--                     os.queueEvent("tmai_ui", "build_status") — изменилось состояние строек.

local util = require("tmai.util")
local json = require("tmai.json")
local u8 = require("tmai.u8")

local M = {}

M.PROTO = "tmai_build"
M.PLANS_DIR = util.DATA_DIR .. "/plans"
local STATE_PATH = util.DATA_DIR .. "/build_state.json"
-- Пределы плана: время работы черепашки, размер сообщения rednet, память компьютера.
M.LIMITS = { x = 48, y = 32, z = 48, blocks = 6000, materials = 12, parts = 200, plans = 50 }
local CONFIRM_TTL = 300        -- код «да КОД» живёт 5 минут
local OFFLINE_AFTER = 100      -- черепашка молчит дольше (hello раз в 30 с) — «нет связи»
local NOTIFY_GAP = 45          -- о ходе одной стройки — в чат не чаще раза в N секунд
local ACTIVE = { sent = true, building = true, waiting = true, paused = true, blocked = true, lost = true, error = true }
-- фаза черепашки (tmbuild) -> состояние стройки здесь
local TURTLE_STATE = { build = "building", wait = "waiting", paused = "paused", blocked = "blocked", error = "error",
  lost = "lost", done = "done" }

-- ============================================================ текст на экране
-- tmai.text — кириллица шрифтом сборки (CP1251): text.cc(utf8) -> байты терминала, text.len — ширина в клетках,
-- text.fit, text.wrap. Строки здесь в UTF-8, на экран — только через tcc/write_at.
local text = require("tmai.text")
local function tlen(s) return text.len(s) end
local function tcc(s) return text.cc(s) end
-- обрезать до w клеток (без дополнения пробелами)
local function fit(s, w)
  if w <= 0 then return "" end
  if tlen(s) <= w then return s end
  return (text.fit(s, w):gsub(" +$", ""))
end
local function wrap(s, w) return text.wrap(s, w) end

-- ============================================================ цвета материалов
local C = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, gray = 128,
  lightGray = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
local HEX = {}
do local v = 1; for i = 0, 15 do HEX[v] = string.format("%x", i); v = v * 2 end end
local DARK = { [C.gray] = true, [C.brown] = true, [C.blue] = true, [C.purple] = true, [C.red] = true, [C.green] = true,
  [C.magenta] = true }
-- цвет по красителю в начале id (длинные названия раньше коротких)
local DYES = { { "light_blue", C.lightBlue }, { "light_gray", C.lightGray }, { "magenta", C.magenta },
  { "orange", C.orange }, { "yellow", C.yellow }, { "purple", C.purple }, { "white", C.white }, { "black", C.gray },
  { "brown", C.brown }, { "green", C.green }, { "lime", C.lime }, { "pink", C.pink }, { "gray", C.gray },
  { "cyan", C.cyan }, { "blue", C.blue }, { "red", C.red } }
local COLOR_RULES = {
  { "glass", C.lightBlue }, { "ice", C.lightBlue }, { "lantern", C.yellow }, { "torch", C.yellow },
  { "glowstone", C.yellow }, { "lamp", C.yellow }, { "stone_brick", C.gray }, { "deepslate", C.gray },
  { "blackstone", C.gray }, { "cobble", C.gray }, { "nether_brick", C.red }, { "mud_brick", C.brown },
  { "brick", C.red }, { "sandstone", C.yellow }, { "sand", C.yellow }, { "quartz", C.white }, { "snow", C.white },
  { "calcite", C.white }, { "birch", C.yellow }, { "bamboo", C.yellow }, { "cherry", C.pink }, { "mangrove", C.red },
  { "crimson", C.red }, { "warped", C.cyan }, { "acacia", C.orange }, { "jungle", C.orange }, { "copper", C.orange },
  { "terracotta", C.orange }, { "dark_oak", C.brown }, { "oak", C.brown }, { "spruce", C.brown },
  { "planks", C.brown }, { "log", C.brown }, { "wood", C.brown }, { "dirt", C.brown }, { "mud", C.brown },
  { "leaves", C.green }, { "moss", C.green }, { "grass", C.green }, { "prismarine", C.cyan }, { "diamond", C.cyan },
  { "emerald", C.lime }, { "purpur", C.purple }, { "obsidian", C.purple }, { "amethyst", C.purple },
  { "gold", C.yellow }, { "iron", C.lightGray }, { "tuff", C.gray }, { "basalt", C.gray }, { "stone", C.lightGray },
  { "andesite", C.lightGray }, { "diorite", C.white }, { "granite", C.pink },
}
local SPARE = { C.orange, C.lime, C.magenta, C.cyan, C.yellow, C.pink, C.lightBlue, C.purple, C.green, C.red,
  C.blue, C.white }

local function color_of(item, i)
  local path = (item or ""):match(":(.+)$") or ""
  for _, d in ipairs(DYES) do
    if path:sub(1, #d[1] + 1) == d[1] .. "_" then return d[2] end
  end
  for _, r in ipairs(COLOR_RULES) do
    if path:find(r[1], 1, true) then return r[2] end
  end
  return SPARE[((i or 1) - 1) % #SPARE + 1]
end

-- ============================================================ проверка материалов
local ITEM_ID = "^[a-z0-9_%.%-]+:[a-z0-9_/%.%-]+$"
local FORBID = {
  { "_door$", "двери черепашка ставит плохо (две половины, петли): оставь проём clear 1×2, дверь поставит игрок" },
  { "_bed$", "кровать — два блока с ориентацией: её ставит игрок" },
  { "chest$", "сундук ставит игрок" },
  { "shulker_box$", "шалкер ставит игрок" },
  { "bucket$", "жидкости черепашка не строит" },
  { "^minecraft:water$", "жидкости черепашка не строит" },
  { "^minecraft:lava$", "жидкости черепашка не строит" },
  { "^minecraft:air$", "воздух — это фигура clear" },
  { "spawn_egg$", "яйца призыва не ставятся" },
  { "^minecraft:tnt$", "взрывчатка запрещена" },
}
local WARN = {
  { "_stairs$", "ступени встанут повёрнутыми по черепашке — для крыши лучше полные блоки или плиты (half)" },
  { "_trapdoor$", "люк сориентируется по черепашке" },
  { "_fence_gate$", "калитка сориентируется по черепашке" },
  { "_button$", "кнопку лучше поставить вручную" },
  { "lever$", "рычаг лучше поставить вручную" },
  { "_sign$", "табличку лучше поставить вручную" },
  { "_banner$", "флаг лучше поставить вручную" },
  { "ladder$", "лестница цепляется к стене — сверху не ставится, поставь вручную" },
  { "vine$", "лозу лучше поставить вручную" },
  { "torch$", "факел встанет только на блок под ним (не в воздух)" },
  { "lantern$", "фонарь встанет только на блок под ним" },
  { "_carpet$", "ковёр встанет только на блок под ним" },
  { "_pressure_plate$", "нажимная плита встанет только на блок под ним" },
  { "^minecraft:redstone$", "редстоун-пыль встанет только на блок под ней" },
  { "^minecraft:sand$", "песок упадёт, если под ним пусто" },
  { "^minecraft:red_sand$", "песок упадёт, если под ним пусто" },
  { "gravel$", "гравий упадёт, если под ним пусто" },
  { "concrete_powder$", "сухой бетон упадёт, если под ним пусто" },
  { "anvil$", "наковальня падает" },
  { "_head$", "голова сориентируется по черепашке" },
  { "_skull$", "череп сориентируется по черепашке" },
  { "furnace$", "печь сориентируется по черепашке" },
  { "glazed_terracotta$", "узор глазурованной керамики повернётся по черепашке" },
}

local function check_item(item)
  if type(item) ~= "string" or not item:match(ITEM_ID) then
    return nil, "item должен быть ID вида minecraft:stone_bricks"
  end
  for _, r in ipairs(FORBID) do
    if item:find(r[1]) then return nil, item .. ": " .. r[2] end
  end
  for _, r in ipairs(WARN) do
    if item:find(r[1]) then return true, item .. ": " .. r[2] end
  end
  return true
end

-- ============================================================ фигуры плана -> клетки
local function int(v)
  if type(v) == "number" and v == math.floor(v) and v >= -1000 and v <= 1000 then return math.floor(v) end
  return nil
end

-- [a,b,c] или {x=,y=,z=}; n = 2 — [x,z]
local function vec(v, n)
  if type(v) ~= "table" then return nil end
  local a, b, c
  if v[1] ~= nil then a, b, c = int(v[1]), int(v[2]), int(v[3])
  elseif n == 2 then a, b = int(v.x), int(v.z)
  else a, b, c = int(v.x), int(v.y), int(v.z) end
  if n == 2 then
    if a and b then return a, b end
    return nil
  end
  if a and b and c then return a, b, c end
  return nil
end

local function order(a, b) if a <= b then return a, b end return b, a end

-- Каждая фигура: prepare(p, ch, ctx) -> bounds {x0,x1,y0,y1,z0,z1}, emit(set) | nil, "ошибка".
-- ctx = { mats = {ключ=...}, warn = function(text) }
local SHAPES = {}

local function box_like(kind)
  return function(p, ch)
    local ax, ay, az = vec(p.from, 3)
    local bx, by, bz = vec(p.to, 3)
    if not ax or not bx then return nil, "нужны from и to вида [x,y,z] (целые числа)" end
    local x0, x1 = order(ax, bx)
    local y0, y1 = order(ay, by)
    local z0, z1 = order(az, bz)
    return { x0, x1, y0, y1, z0, z1 }, function(set)
      for y = y0, y1 do
        for z = z0, z1 do
          for x = x0, x1 do
            if kind == "fill" or (kind == "walls" and (x == x0 or x == x1 or z == z0 or z == z1))
              or (kind == "box" and (x == x0 or x == x1 or y == y0 or y == y1 or z == z0 or z == z1)) then
              set(x, y, z, ch)
            end
          end
        end
      end
    end
  end
end
SHAPES.fill = box_like("fill")
SHAPES.box = box_like("box")
SHAPES.walls = box_like("walls")
SHAPES.clear = box_like("fill")

SHAPES.floor = function(p, ch, ctx)
  local ax, ay, az = vec(p.from, 3)
  local bx, by, bz = vec(p.to, 3)
  if not ax then return nil, "нужны from и to вида [x,y,z]" end
  if not bx then
    local x, z = vec(p.to, 2)
    if not x then return nil, "нужны from и to вида [x,y,z]" end
    bx, by, bz = x, ay, z
  end
  if by ~= ay then ctx.warn("floor — один слой: взят y из from (" .. ay .. ")") end
  return SHAPES.fill({ from = { ax, ay, az }, to = { bx, ay, bz } }, ch)
end

SHAPES.line = function(p, ch)
  local ax, ay, az = vec(p.from, 3)
  local bx, by, bz = vec(p.to, 3)
  if not ax or not bx then return nil, "нужны from и to вида [x,y,z]" end
  local x0, x1 = order(ax, bx)
  local y0, y1 = order(ay, by)
  local z0, z1 = order(az, bz)
  return { x0, x1, y0, y1, z0, z1 }, function(set)
    local n = math.max(math.abs(bx - ax), math.abs(by - ay), math.abs(bz - az))
    for i = 0, n do
      local t = n == 0 and 0 or i / n
      set(math.floor(ax + (bx - ax) * t + 0.5), math.floor(ay + (by - ay) * t + 0.5),
        math.floor(az + (bz - az) * t + 0.5), ch)
    end
  end
end

SHAPES.cylinder = function(p, ch)
  local cx, cz = vec(p.center, 2)
  if p.center and p.center[3] ~= nil then cx, cz = int(p.center[1]), int(p.center[3]) end
  if not cx or not cz then return nil, "нужен center: [x,z]" end
  local y0, y1
  if type(p.y) == "table" then y0, y1 = int(p.y[1]), int(p.y[2] or p.y[1]) else y0 = int(p.y); y1 = y0 end
  if not y0 or not y1 then return nil, "нужен y: [y0,y1] (нижний и верхний слой)" end
  y0, y1 = order(y0, y1)
  local r = int(p.r)
  if not r or r < 1 or r > 24 then return nil, "r — целое 1..24" end
  local hollow = p.hollow == true
  local function inside(dx, dz) return dx * dx + dz * dz <= r * r + r end
  return { cx - r, cx + r, y0, y1, cz - r, cz + r }, function(set)
    for dz = -r, r do
      for dx = -r, r do
        if inside(dx, dz) and (not hollow or not (inside(dx + 1, dz) and inside(dx - 1, dz)
          and inside(dx, dz + 1) and inside(dx, dz - 1))) then
          for y = y0, y1 do set(cx + dx, y, cz + dz, ch) end
        end
      end
    end
  end
end

-- Крыша: from [x0,y,z0], to [x1,(y),z1] — прямоугольник по x,z, y — основание. style: gable (двускатная, конёк
-- вдоль axis), flat, pyramid (четырёхскатная). half — ключ плиты: скат в полблока на клетку (плита, блок, плита…).
-- ends — ключ материала фронтонов (треугольные стены на торцах двускатной крыши).
SHAPES.roof = function(p, ch, ctx)
  local ax, yb, az = vec(p.from, 3)
  if not ax then return nil, "нужен from: [x0,y,z0] (y — основание крыши)" end
  local bx, bz
  if type(p.to) == "table" and p.to[3] == nil and p.to[1] ~= nil then bx, bz = vec(p.to, 2)
  else local x, _, z = vec(p.to, 3); bx, bz = x, z end
  if not bx then return nil, "нужен to: [x1,y,z1]" end
  local x0, x1 = order(ax, bx)
  local z0, z1 = order(az, bz)
  local style = p.style or "gable"
  if style ~= "gable" and style ~= "flat" and style ~= "pyramid" then return nil, "style: gable | flat | pyramid" end
  local axis = p.axis or ((x1 - x0) >= (z1 - z0) and "x" or "z")
  if axis ~= "x" and axis ~= "z" then return nil, "axis: x | z (вдоль какой оси конёк)" end
  local half = p.half
  if half ~= nil and (type(half) ~= "string" or not ctx.mats[half]) then return nil, "half — ключ материала-плиты из materials" end
  local ends = p.ends
  if ends ~= nil and (type(ends) ~= "string" or not ctx.mats[ends]) then return nil, "ends — ключ материала из materials" end
  if ends and style ~= "gable" then ctx.warn("roof: ends бывают только у двускатной крыши (gable)") end
  -- высота k-й ступени и её материал
  local function step(k)
    if half then return yb + math.floor(k / 2), (k % 2 == 0) and half or ch end
    return yb + k, ch
  end
  local span
  if style == "flat" then span = 1
  elseif style == "gable" then span = (axis == "x") and (z1 - z0 + 1) or (x1 - x0 + 1)
  else span = math.min(x1 - x0 + 1, z1 - z0 + 1) end
  local kmax = math.floor((span - 1) / 2)
  local ytop = step(kmax)
  return { x0, x1, yb, math.max(yb, ytop), z0, z1 }, function(set)
    if style == "flat" then
      for z = z0, z1 do for x = x0, x1 do set(x, yb, z, ch) end end
    elseif style == "gable" then
      -- u — поперёк конька, v — вдоль
      local u0, u1, v0, v1 = z0, z1, x0, x1
      if axis == "z" then u0, u1, v0, v1 = x0, x1, z0, z1 end
      local function put(u, v, y, m) if axis == "x" then set(v, y, u, m) else set(u, y, v, m) end end
      for k = 0, kmax do
        local y, m = step(k)
        for v = v0, v1 do put(u0 + k, v, y, m); put(u1 - k, v, y, m) end
      end
      if ends then
        -- фронтоны: треугольные стены на торцах (v0 и v1) под скатом
        for u = u0, u1 do
          local yk = step(math.min(u - u0, u1 - u, kmax))
          for yy = yb, yk - 1 do put(u, v0, yy, ends); put(u, v1, yy, ends) end
        end
      end
    else -- pyramid
      for k = 0, kmax do
        local y, m = step(k)
        local ax0, ax1, az0, az1 = x0 + k, x1 - k, z0 + k, z1 - k
        for z = az0, az1 do
          for x = ax0, ax1 do
            if x == ax0 or x == ax1 or z == az0 or z == az1 then set(x, y, z, m) end
          end
        end
      end
    end
  end
end

-- Рисунок слоя: y, rows = { "SS.S", ... } — rows[1] — ряд z = at[2] (ближний к черепашке), символ j — x = at[1]+j-1.
-- "." или пробел — не трогать, "-" — расчистить (воздух), иначе ключ материала.
SHAPES.layer = function(p, _, ctx)
  local y = int(p.y)
  if not y then return nil, "нужен y — номер слоя (целое)" end
  if type(p.rows) ~= "table" or #p.rows == 0 then return nil, "нужен rows — массив строк рисунка" end
  if #p.rows > M.LIMITS.z then return nil, "rows: не больше " .. M.LIMITS.z .. " строк" end
  local ox, oz = 0, 0
  local at = p.at or p.origin
  if at ~= nil then
    ox, oz = vec(at, 2)
    if not ox then return nil, "at — [x,z] левого ближнего угла рисунка" end
  end
  local w = 0
  for i, row in ipairs(p.rows) do
    if type(row) ~= "string" then return nil, "rows[" .. i .. "] — не строка" end
    if #row > M.LIMITS.x then return nil, "rows[" .. i .. "]: не больше " .. M.LIMITS.x .. " символов" end
    for j = 1, #row do
      local c = row:sub(j, j)
      if c ~= "." and c ~= " " and c ~= "-" and not ctx.mats[c] then
        return nil, "rows[" .. i .. "]: символ «" .. c .. "» не описан в materials"
      end
    end
    w = math.max(w, #row)
  end
  if w == 0 then return nil, "rows пустые" end
  return { ox, ox + w - 1, y, y, oz, oz + #p.rows - 1 }, function(set)
    for i, row in ipairs(p.rows) do
      for j = 1, #row do
        local c = row:sub(j, j)
        if c ~= "." and c ~= " " then set(ox + j - 1, y, oz + i - 1, c) end
      end
    end
  end
end

local NEEDS_MAT = { fill = true, box = true, walls = true, floor = true, line = true, cylinder = true, roof = true }

-- RLE строки слоя: "SSSS..GG" -> "4S2.2G" (ключи — буквы, поэтому цифры однозначны)
local function rle(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local j = i
    while j < n and s:sub(j + 1, j + 1) == c do j = j + 1 end
    out[#out + 1] = (j > i and tostring(j - i + 1) or "") .. c
    i = j + 1
  end
  return table.concat(out)
end
local function unrle(s)
  return (s:gsub("(%d*)(%D)", function(k, c) return c:rep(tonumber(k) or 1) end))
end
M.rle, M.unrle = rle, unrle

-- Проверить и вокселизовать план. -> compiled | nil, { ошибки }, { предупреждения }
-- compiled = { name, materials = { K = {item, name} }, parts, ox, sx, sy, sz, layers = { [y+1] = { rle-строки по z } },
--              counts = { K = n }, blocks, warnings }
function M.compile(plan)
  local errs, warns = {}, {}
  local function err(s) if #errs < 12 then errs[#errs + 1] = s end end
  if type(plan) ~= "table" then return nil, { "план — объект {name, materials, parts}" }, warns end
  local name = type(plan.name) == "string" and u8.trim(plan.name) or ""
  if name == "" then name = "Постройка" end
  name = u8.truncate(name, 60)
  -- материалы
  local mats, nmat = {}, 0
  if type(plan.materials) ~= "table" then err("materials — объект {\"S\": {\"item\": \"minecraft:stone_bricks\", \"name\": \"каменные кирпичи\"}}")
  else
    for k, v in pairs(plan.materials) do
      if type(k) ~= "string" or not k:match("^[A-Za-z]$") then
        err("materials: ключ «" .. tostring(k) .. "» — одна латинская буква (A-Z, a-z)")
      else
        if type(v) == "string" then v = { item = v } end
        local item = type(v) == "table" and v.item
        if type(item) == "string" and item:match("^[a-z0-9_]+$") then item = "minecraft:" .. item end
        local ok, msg = check_item(item)
        if not ok then err("materials." .. k .. ": " .. msg)
        else
          if msg then warns[#warns + 1] = msg end
          local nm = type(v.name) == "string" and u8.truncate(u8.trim(v.name), 40) or ""
          mats[k] = { item = item, name = nm ~= "" and nm or (item:match("([^:/]+)$"):gsub("_", " ")) }
          nmat = nmat + 1
        end
      end
    end
    if nmat == 0 and #errs == 0 then err("materials пуст") end
    if nmat > M.LIMITS.materials then err("материалов больше " .. M.LIMITS.materials .. " — черепашке не хватит слотов") end
  end
  if type(plan.parts) ~= "table" or #plan.parts == 0 then err("parts — непустой массив фигур") end
  if #errs > 0 then return nil, errs, warns end
  if #plan.parts > M.LIMITS.parts then return nil, { "фигур больше " .. M.LIMITS.parts }, warns end
  -- 1) проверка фигур и общие границы
  local prepared = {}
  local bx0, bx1, by0, by1, bz0, bz1
  local ctx = { mats = mats, warn = function(s) warns[#warns + 1] = s end }
  for i, p in ipairs(plan.parts) do
    local where = "parts[" .. i .. "]"
    if type(p) ~= "table" then err(where .. ": не объект")
    else
      local kind = p.type or p.shape
      local fn = type(kind) == "string" and SHAPES[kind]
      where = where .. " (" .. tostring(kind) .. ")"
      if not fn then err(where .. ": неизвестная фигура; есть fill, box, walls, floor, clear, line, cylinder, roof, layer")
      else
        local ch = p.m or p.material
        if kind == "clear" then ch = "-"
        elseif NEEDS_MAT[kind] and (type(ch) ~= "string" or not mats[ch]) then
          err(where .. ": m — ключ материала из materials" .. (ch and (", а «" .. tostring(ch) .. "» не описан") or ""))
          fn = nil
        end
        if fn then
          ctx.warn = function(s) warns[#warns + 1] = where .. ": " .. s end
          local b, emit = fn(p, ch, ctx)
          if not b then err(where .. ": " .. tostring(emit))
          else
            local dx, dy, dz = b[2] - b[1] + 1, b[4] - b[3] + 1, b[6] - b[5] + 1
            if dx > M.LIMITS.x or dy > M.LIMITS.y or dz > M.LIMITS.z then
              err(where .. ": фигура " .. dx .. "×" .. dy .. "×" .. dz .. " больше предела " ..
                M.LIMITS.x .. "×" .. M.LIMITS.y .. "×" .. M.LIMITS.z)
            else
              prepared[#prepared + 1] = { emit = emit, kind = kind, volume = dx * dy * dz }
              bx0 = bx0 and math.min(bx0, b[1]) or b[1]; bx1 = bx1 and math.max(bx1, b[2]) or b[2]
              by0 = by0 and math.min(by0, b[3]) or b[3]; by1 = by1 and math.max(by1, b[4]) or b[4]
              bz0 = bz0 and math.min(bz0, b[5]) or b[5]; bz1 = bz1 and math.max(bz1, b[6]) or b[6]
            end
          end
        end
      end
    end
  end
  if #errs > 0 then return nil, errs, warns end
  if by0 < 0 then err("y < 0: черепашка строит только вверх от своего уровня (y = 0 — её уровень)") end
  if bz0 < 0 then err("z < 0 — это позади черепашки (там она сама и сундук); начинай с z = 0") end
  if bx1 - bx0 + 1 > M.LIMITS.x or by1 + 1 > M.LIMITS.y or bz1 + 1 > M.LIMITS.z then
    err(string.format("постройка %d×%d×%d (x×y×z, от 0) больше предела %d×%d×%d", bx1 - bx0 + 1, by1 + 1, bz1 + 1,
      M.LIMITS.x, M.LIMITS.y, M.LIMITS.z))
  end
  if #errs > 0 then return nil, errs, warns end
  -- 2) вокселизация: поздние фигуры перекрывают ранние
  local ox, sx, sy, sz = bx0, bx1 - bx0 + 1, by1 + 1, bz1 + 1
  local cells = {}
  local function set(x, y, z, ch)
    if x >= ox and x < ox + sx and y >= 0 and y < sy and z >= 0 and z < sz then
      cells[(y * sz + z) * sx + (x - ox) + 1] = ch
    end
  end
  local work = 0
  for _, pp in ipairs(prepared) do
    pp.emit(set)
    work = work + pp.volume
    if work > 100000 and os.queueEvent then util.yield(); work = 0 end   -- «Too long without yielding»
  end
  local layers, counts, blocks = {}, {}, 0
  for y = 0, sy - 1 do
    local rows = {}
    for z = 0, sz - 1 do
      local buf = {}
      local base = (y * sz + z) * sx
      for x = 1, sx do
        local ch = cells[base + x] or "."
        buf[x] = ch
        if ch ~= "." and ch ~= "-" then counts[ch] = (counts[ch] or 0) + 1; blocks = blocks + 1 end
      end
      rows[z + 1] = rle(table.concat(buf))
    end
    layers[y + 1] = rows
  end
  if blocks == 0 then return nil, { "в плане нет ни одного блока" }, warns end
  if blocks > M.LIMITS.blocks then
    return nil, { "блоков " .. blocks .. " — больше предела " .. M.LIMITS.blocks .. "; раздели постройку на части" }, warns
  end
  for k in pairs(mats) do
    if not counts[k] then warns[#warns + 1] = "материал " .. k .. " (" .. mats[k].name .. ") нигде не стоит" end
  end
  return { name = name, materials = mats, parts = plan.parts, ox = ox, sx = sx, sy = sy, sz = sz, layers = layers,
    counts = counts, blocks = blocks, warnings = warns }, nil, warns
end

-- ============================================================ хранилище планов
local decoded = {}   -- id -> { [y+1] = { [z+1] = "строка" } }
local meta_cache = {}

local function plan_path(id) return M.PLANS_DIR .. "/" .. tostring(id) .. ".json" end

function M.get_plan(id)
  id = tonumber(id)
  if not id then return nil end
  local p = util.load_json(plan_path(math.floor(id)), nil)
  if type(p) ~= "table" or type(p.layers) ~= "table" then return nil end
  return p
end

local function plan_ids()
  local ids = {}
  if fs.exists(M.PLANS_DIR) and fs.list then
    for _, f in ipairs(fs.list(M.PLANS_DIR)) do
      local n = tonumber(f:match("^(%d+)%.json$"))
      if n then ids[#ids + 1] = n end
    end
  end
  table.sort(ids)
  return ids
end

-- клетки слоя (декодированные строки по z)
local function rows_of(plan, y)
  local d = decoded[plan.id]
  if not d or d.stamp ~= plan.created then d = { stamp = plan.created }; decoded[plan.id] = d end
  if not d[y + 1] then
    local rows = {}
    for z, r in ipairs(plan.layers[y + 1] or {}) do rows[z] = unrle(r) end
    d[y + 1] = rows
  end
  return d[y + 1]
end

-- Порядок клеток слоя — как у черепашки (tmbuild.lua, layer_cells): змейка по рядам z, x туда-обратно.
local function cell_order(plan, y)
  local rows, list = rows_of(plan, y), {}
  for z = 0, plan.sz - 1 do
    local row = rows[z + 1] or ""
    local a, b, s = 1, plan.sx, 1
    if z % 2 == 1 then a, b, s = plan.sx, 1, -1 end
    for i = a, b, s do
      local ch = row:sub(i, i)
      if ch ~= "." and ch ~= "" then list[#list + 1] = { x = plan.ox + i - 1, z = z, ch = ch } end
    end
  end
  return list
end

-- Смета: { {key, item, name, count}, ... } по убыванию
local function smeta(plan, from_layer)
  local counts = {}
  if from_layer and from_layer > 1 then
    for y = from_layer - 1, plan.sy - 1 do
      for _, row in ipairs(rows_of(plan, y)) do
        for c in row:gmatch("%a") do counts[c] = (counts[c] or 0) + 1 end
      end
    end
  else
    counts = plan.counts or {}
  end
  local out = {}
  for k, n in pairs(counts) do
    local m = plan.materials[k] or {}
    out[#out + 1] = { key = k, item = m.item, name = m.name, count = n }
  end
  table.sort(out, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.key < b.key end)
  return out
end
M.smeta = smeta

-- Оценка ходов/топлива/времени (грубо: путь змейкой + рейсы к сундуку).
local function estimate(plan)
  local moves = 0
  for y = 0, plan.sy - 1 do
    local list = cell_order(plan, y)
    for i = 2, #list do
      moves = moves + math.abs(list[i].x - list[i - 1].x) + math.abs(list[i].z - list[i - 1].z)
    end
    moves = moves + 2
  end
  local trips = math.ceil((plan.blocks or 0) / 900) + 1
  moves = moves + trips * 2 * (plan.sy + 2 + math.floor((plan.sx + plan.sz) / 2))
  local fuel = math.floor(moves * 1.15) + 40
  return { fuel = fuel, coal = math.ceil(fuel / 80), minutes = math.ceil((moves + (plan.blocks or 0)) * 0.45 / 60) }
end

local function size_text(p) return p.sx .. "×" .. p.sy .. "×" .. p.sz end

-- Сохранить план (новый или заменить id). -> сводка | nil, ошибки, предупреждения
function M.save_plan(plan, id, author)
  local c, errs, warns = M.compile(plan)
  if not c then return nil, errs, warns end
  local ids = plan_ids()
  id = tonumber(id)
  if id then
    id = math.floor(id)
    if id < 1 then return nil, { "id — номер плана из build_list" }, warns end
    for key, j in pairs(M.state().jobs) do
      if j.plan == id and (j.state == "building" or j.state == "waiting" or j.state == "sent") then
        return nil, { "план " .. id .. " сейчас строится черепашкой #" .. key .. " — сначала build_stop или новый план" }, warns
      end
    end
  else
    if #ids >= M.LIMITS.plans then return nil, { "планов уже " .. #ids .. " — удалите старые (build_delete)" }, warns end
    id = (ids[#ids] or 0) + 1
  end
  c.id = id
  c.author = author
  c.created = os.epoch and os.epoch("utc") or 0
  util.save_json(plan_path(id), c)
  decoded[id] = nil
  meta_cache[id] = nil
  util.log("I", "build: plan %d '%s' %s, %d blocks (by %s)", id, c.name, size_text(c), c.blocks, tostring(author))
  return c
end

local function plan_meta(id)
  local m = meta_cache[id]
  if m then return m end
  local p = M.get_plan(id)
  if not p then return nil end
  m = { id = id, name = p.name, size = size_text(p), layers = p.sy, blocks = p.blocks }
  meta_cache[id] = m
  return m
end

function M.list_plans()
  local out = {}
  for _, id in ipairs(plan_ids()) do
    local m = plan_meta(id)
    if m then out[#out + 1] = m end
  end
  return out
end

function M.delete_plan(id)
  id = tonumber(id)
  if not id or not fs.exists(plan_path(id)) then return nil, "нет плана " .. tostring(id) end
  for key, j in pairs(M.state().jobs) do
    if j.plan == id and ACTIVE[j.state] and j.state ~= "error" and j.state ~= "lost" then
      return nil, "план " .. id .. " строится черепашкой #" .. key .. " — сначала build_stop"
    end
  end
  fs.delete(plan_path(id))
  decoded[id], meta_cache[id] = nil, nil
  local s = M.state()
  if s.selected and s.selected.id == id then s.selected = nil end
  M.save_state()
  return true
end

-- ============================================================ состояние строек
local st
local builders = {}     -- id -> { label, fuel, state, store, inv, t, ... } (по hello, не сохраняется)
local pending = {}      -- код -> { plan, builder, player, clear_site, from_layer, expires }

function M.state()
  if not st then
    st = util.load_json(STATE_PATH, {})
    st.jobs = type(st.jobs) == "table" and st.jobs or {}
    st.stores = type(st.stores) == "table" and st.stores or {}
  end
  return st
end
function M.save_state() util.save_json(STATE_PATH, M.state()) end

local function ui_event(...) if os.queueEvent then os.queueEvent("tmai_ui", ...) end end

function M.selected()
  local s = M.state().selected
  if s then return s.id, s.layer end
  return nil
end

function M.select(id, layer)
  local p = M.get_plan(id)
  if not p then return nil, "нет плана " .. tostring(id) end
  layer = math.floor(tonumber(layer) or 1)
  if layer < 1 then layer = 1 elseif layer > p.sy then layer = p.sy end
  M.state().selected = { id = p.id, layer = layer }
  M.save_state()
  ui_event("build", p.id, layer)
  return p, layer
end

local function online(b) return b and util.now() - (b.t or 0) < OFFLINE_AFTER end

function M.list_builders()
  local out = {}
  for id, b in pairs(builders) do
    if online(b) then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

local function job_of(id) return M.state().jobs[tostring(id)] end

local function bname(id)
  local b = builders[id]
  local l = b and b.label or ""
  return "#" .. tostring(id) .. ((l ~= "" and l ~= "?") and (" " .. l) or "")
end

-- имя материала по item (для сообщений): из плана задания, иначе сам ID
local function item_name(plan_id, item)
  local p = plan_id and M.get_plan(plan_id)
  if p then
    for _, m in pairs(p.materials) do
      if m.item == item then return m.name end
    end
  end
  if item == "fuel" then return "топливо (уголь)" end
  return item
end

local function missing_text(j, list)
  local parts = {}
  for i, m in ipairs(list or {}) do
    if i > 6 then parts[#parts + 1] = "…"; break end
    parts[#parts + 1] = item_name(j and j.plan, m.item) .. " ×" .. tostring(m.count)
  end
  return table.concat(parts, ", ")
end

-- ============================================================ rednet: сообщения черепашек
-- Черепашка (tmbuild) -> ИИ, все с from = "tmbuild", owner = id владельца или nil:
--   hello    { label, version, state, job, name, layer, layers, cell, done, total, fuel, fuel_limit,
--              store = {{item,count}}, store_size, inv = {{item,count}}, at_home, tool }
--   inv      { store, store_size, inv, fuel }            — ответ на { op = "inv" }
--   accepted { job } / rejected { job, error }
--   progress { job, layer, layers, cell, done, total, pos = {x,y,z}, skipped }
--   need     { job, missing = {{item,count}}, fuel = bool, blocking = bool }
--   blocked  { job, block, at = {x,y,z}, reason }
--   state    { job, state = paused|resumed|done|stopped|error|lost, error, skipped }
-- ИИ -> черепашка (from = "tmai"): ack, job { job, name, ox, sx, sy, sz, layers, mats, clear_site, from_layer,
--   player }, pause, resume, stop, recheck, inv.
-- Возвращает текст уведомления для чата (или nil) и ник игрока, запустившего стройку.
function M.on_rednet(sender, msg)
  if type(msg) ~= "table" or msg.from ~= "tmbuild" or type(sender) ~= "number" then return nil end
  local me = os.getComputerID()
  if msg.owner ~= nil and msg.owner ~= me then return nil end     -- черепашка другого компьютера ИИ
  local b = builders[sender] or {}
  builders[sender] = b
  b.t = util.now()
  local op = msg.op
  if op == "hello" or op == "inv" then
    for _, k in ipairs({ "label", "version", "fuel", "fuel_limit", "store", "store_size", "inv", "at_home", "tool" }) do
      if msg[k] ~= nil then b[k] = msg[k] end
    end
    if op == "hello" then
      b.state, b.job = msg.state, msg.job
      if msg.owner == nil then rednet.send(sender, { op = "ack", from = "tmai" }, M.PROTO) end
    else
      b.inv_t = util.now()
    end
    -- задание пропало у черепашки (сброс) — пометить
    local j = job_of(sender)
    if op == "hello" and j and ACTIVE[j.state] and j.state ~= "sent" and msg.job ~= j.job then
      j.state = "lost_job"
      M.save_state()
      ui_event("build_status")
      return "Черепашка " .. bname(sender) .. " потеряла задание «" .. tostring(j.name) .. "» (сброс?).", j.player
    end
    local mapped = TURTLE_STATE[msg.state or ""]
    if op == "hello" and j and msg.job == j.job and mapped and j.state ~= mapped then
      j.state = mapped
      M.save_state()
      ui_event("build_status")
    end
    return nil
  end
  local j = job_of(sender)
  if not j or msg.job ~= j.job then return nil end
  j.updated = util.now()
  local text_out
  if op == "accepted" then
    j.state = "building"
    text_out = "Черепашка " .. bname(sender) .. " приступила: «" .. j.name .. "», " .. tostring(j.total or "?") .. " блоков."
  elseif op == "rejected" then
    j.state = "rejected"
    text_out = "Черепашка " .. bname(sender) .. " отказалась от «" .. j.name .. "»: " .. tostring(msg.error)
  elseif op == "progress" then
    local was_layer = j.layer
    for _, k in ipairs({ "layer", "layers", "cell", "done", "total", "pos", "skipped" }) do
      if msg[k] ~= nil then j[k] = msg[k] end
    end
    if j.state ~= "paused" then j.state = "building" end
    j.missing, j.blocked = nil, nil
    if was_layer and msg.layer and msg.layer > was_layer and util.now() - (j.notified_t or 0) >= NOTIFY_GAP then
      j.notified_t = util.now()
      text_out = string.format("Черепашка %s («%s»): слой %d/%d, %d%%.", bname(sender), j.name, msg.layer,
        msg.layers or j.layers or 0, math.floor(100 * (msg.done or 0) / math.max(1, msg.total or 1)))
    end
  elseif op == "need" then
    local sig = (msg.fuel and "F" or "") .. (msg.blocking and "B" or "")
    for _, m in ipairs(msg.missing or {}) do sig = sig .. "|" .. tostring(m.item) .. "=" .. tostring(m.count) end
    j.missing = msg.missing
    if msg.blocking then j.state = "waiting" end
    if sig ~= j.missing_sig then
      j.missing_sig = sig
      local list = missing_text(j, msg.missing)
      if msg.blocking then
        local what = {}
        if list ~= "" then what[#what + 1] = list end
        if msg.fuel then what[#what + 1] = "топлива (уголь)" end
        text_out = "Черепашка " .. bname(sender) .. " («" .. j.name .. "») ждёт у сундука: не хватает " ..
          table.concat(what, ", ") .. ". Положите в её сундук."
      elseif list ~= "" then
        text_out = "Черепашка " .. bname(sender) .. " («" .. j.name .. "»): на всю постройку не хватит " .. list ..
          " — доложите в сундук, стройка идёт."
      end
    end
  elseif op == "blocked" then
    local at = msg.at or {}
    local sig = tostring(msg.block) .. "@" .. tostring(at[1]) .. "," .. tostring(at[2]) .. "," .. tostring(at[3])
    j.blocked = { block = msg.block, at = at, reason = msg.reason }
    if msg.reason ~= "skip" then j.state = "blocked" end
    if sig ~= j.blocked_sig then
      j.blocked_sig = sig
      local where = string.format("(%s, %s, %s)", tostring(at[1]), tostring(at[2]), tostring(at[3]))
      if msg.reason == "skip" then
        text_out = "Черепашка " .. bname(sender) .. ": клетка " .. where .. " занята блоком " .. tostring(msg.block) ..
          " — пропускаю."
      elseif msg.reason == "natural" then
        text_out = "Черепашка " .. bname(sender) .. " («" .. j.name .. "»): мешает " .. tostring(msg.block) .. " " .. where ..
          ". Уберите его или запустите стройку с расчисткой площадки."
      elseif msg.reason == "entity" then
        text_out = "Черепашка " .. bname(sender) .. ": путь загородило существо " .. where .. ", жду."
      else
        text_out = "Черепашка " .. bname(sender) .. " («" .. j.name .. "»): путь перекрыт (" .. tostring(msg.block) ..
          " " .. where .. "), жду. Уберите помеху и скажите «продолжить»."
      end
    end
  elseif op == "state" then
    local s = msg.state
    if s == "resumed" then j.state = "building" else j.state = s end
    if msg.skipped then j.skipped = msg.skipped end
    if s == "done" then
      j.done = j.total
      text_out = "Черепашка " .. bname(sender) .. ": «" .. j.name .. "» построено" ..
        ((msg.skipped or 0) > 0 and (", пропущено клеток: " .. msg.skipped) or "") .. "."
    elseif s == "paused" then text_out = "Черепашка " .. bname(sender) .. ": стройка «" .. j.name .. "» на паузе."
    elseif s == "resumed" then text_out = nil
    elseif s == "stopped" then text_out = "Черепашка " .. bname(sender) .. ": стройка «" .. j.name .. "» остановлена" ..
        (msg.error and (" (" .. tostring(msg.error) .. ")") or "") .. "."
    elseif s == "error" then text_out = "Черепашка " .. bname(sender) .. ": ошибка стройки «" .. j.name .. "»: " ..
        tostring(msg.error):sub(1, 200)
    elseif s == "lost" then text_out = "Черепашка " .. bname(sender) .. " потеряла ориентацию: поставьте её на стартовую " ..
        "клетку лицом к стройке (сундук позади) и скажите «продолжить»."
    end
  end
  M.save_state()
  ui_event("build_status")
  return text_out, j.player
end

-- Запросить у черепашки свежее содержимое склада (ждёт ответа до timeout секунд).
local function request_inv(id, timeout)
  local b = builders[id]
  if not b then return false end
  local t0 = util.now()
  rednet.send(id, { op = "inv", from = "tmai" }, M.PROTO)
  if (b.inv_t or 0) >= t0 then return true end
  if not os.startTimer then return false end
  local timer = os.startTimer(timeout or 3)
  while true do
    local ev, a, msg, proto = os.pullEvent()
    if ev == "timer" and a == timer then return false end
    if ev == "rednet_message" and a == id and proto == M.PROTO and type(msg) == "table" and msg.op == "inv" then
      M.on_rednet(a, msg)
      return true
    end
    if (b.inv_t or 0) >= t0 then return true end
  end
end

local function agg(list, into)
  into = into or {}
  for _, it in ipairs(list or {}) do
    if it.item then into[it.item] = (into[it.item] or 0) + (tonumber(it.count) or 0) end
  end
  return into
end

local FUEL_VALUE = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
  ["minecraft:blaze_rod"] = 120, ["minecraft:dried_kelp_block"] = 200, ["minecraft:lava_bucket"] = 1000 }

-- Сверка сметы со складом черепашки: { need, missing, fuel = {...}, ok }
function M.check(id, builder, from_layer)
  local plan = M.get_plan(id)
  if not plan then return nil, "нет плана " .. tostring(id) .. " (build_list)" end
  builder = tonumber(builder)
  local b = builder and builders[builder]
  if not online(b) then return nil, "черепашка " .. tostring(builder) .. " не на связи (build_builders)" end
  request_inv(builder, 3)
  local have = agg(b.inv, agg(b.store))
  local need, missing = smeta(plan, from_layer), {}
  for _, m in ipairs(need) do
    local short = m.count - (have[m.item] or 0)
    if short > 0 then missing[#missing + 1] = { item = m.item, name = m.name, count = short } end
  end
  local est = estimate(plan)
  local fuel_have = type(b.fuel) == "number" and b.fuel or 0
  for item, v in pairs(FUEL_VALUE) do fuel_have = fuel_have + (have[item] or 0) * v end
  local fuel = { need = est.fuel, have = b.fuel == "unlimited" and "unlimited" or fuel_have,
    coal_short = (b.fuel ~= "unlimited" and fuel_have < est.fuel) and math.ceil((est.fuel - fuel_have) / 80) or 0 }
  return { plan = plan.id, name = plan.name, builder = builder, need = need, missing = missing, fuel = fuel,
    minutes = est.minutes, ok = #missing == 0 and fuel.coal_short == 0,
    store_seen = b.inv_t and math.floor(util.now() - b.inv_t) or nil }
end

-- ============================================================ запуск, подтверждение, остановка
local function new_code()
  local scripts_ok, scripts = pcall(require, "tmai.scripts")
  for _ = 1, 50 do
    local c = string.format("%03d", math.random(100, 999))
    if not pending[c] and not (scripts_ok and scripts.is_job and scripts.is_job(c)) then return c end
  end
  return string.format("%03d", math.random(100, 999))
end

local function busy(id)
  local j = job_of(id)
  if j and (j.state == "sent" or j.state == "building" or j.state == "waiting" or j.state == "paused"
    or j.state == "blocked") then return j end
  local b = builders[id]
  if b and b.job and b.state and b.state ~= "idle" and b.state ~= "done" then return b end
  return nil
end

-- Подготовить стройку: код подтверждения (как script_propose). Запуск — build.confirm по «да КОД» игрока.
function M.start(args, player)
  local plan = M.get_plan(args.id)
  if not plan then return nil, "нет плана " .. tostring(args.id) .. " (build_list)" end
  local builder = tonumber(args.builder)
  if not builder then
    local list = M.list_builders()
    if #list == 1 then builder = list[1] end
  end
  local b = builder and builders[builder]
  if not online(b) then return nil, "черепашка " .. tostring(builder) .. " не на связи — список: build_builders" end
  if busy(builder) then return nil, "черепашка " .. bname(builder) .. " занята другой стройкой (build_status, build_stop)" end
  local from_layer = math.floor(tonumber(args.from_layer) or 1)
  if from_layer < 1 or from_layer > plan.sy then return nil, "from_layer — 1.." .. plan.sy end
  local code = new_code()
  pending[code] = { plan = plan.id, builder = builder, player = player, clear_site = args.clear_site == true,
    from_layer = from_layer, expires = util.now() + CONFIRM_TTL }
  local chk = M.check(plan.id, builder, from_layer)
  local res = { status = "awaiting_confirmation", code = code, plan = plan.id, builder = builder,
    say = string.format("Стройка «%s» (план %d, %s, %d блоков) на черепашке %s. Для запуска игрок пишет «да %s» (код действует 5 минут).",
      plan.name, plan.id, size_text(plan), plan.blocks, bname(builder), code) }
  if chk then
    res.missing, res.fuel, res.minutes = chk.missing, chk.fuel, chk.minutes
    if not chk.ok then res.note = "Не всё есть на складе: черепашка начнёт и будет ждать у сундука недостающее." end
  end
  if args.clear_site == true and b.tool == false then
    res.warning = "у черепашки нет кирки — расчистка площадки не получится"
  end
  ui_event("build_status")
  return res
end

function M.is_job(code)
  local p = pending[tostring(code)]
  return p ~= nil
end

-- Игрок подтвердил «да КОД» (вызывает интерфейс, минуя нейросеть). -> текст для чата | nil, ошибка
function M.confirm(code, player)
  code = tostring(code)
  local p = pending[code]
  if not p then return nil, "нет стройки с таким кодом" end
  pending[code] = nil
  if util.now() > p.expires then return nil, "код истёк — попросите запустить стройку снова" end
  local plan = M.get_plan(p.plan)
  if not plan then return nil, "план " .. p.plan .. " удалён" end
  local b = builders[p.builder]
  if not online(b) then return nil, "черепашка #" .. p.builder .. " не на связи" end
  if busy(p.builder) then return nil, "черепашка " .. bname(p.builder) .. " уже занята" end
  local mats = {}
  for k, m in pairs(plan.materials) do mats[k] = m.item end
  local total = 0
  for y = p.from_layer - 1, plan.sy - 1 do total = total + #cell_order(plan, y) end
  local jid = string.format("%d-%d", plan.id, math.floor((os.epoch and os.epoch("utc") or 0) / 1000) % 1000000)
  M.state().jobs[tostring(p.builder)] = { job = jid, plan = plan.id, name = plan.name, builder = p.builder,
    player = player or p.player, state = "sent", layer = p.from_layer, layers = plan.sy, done = 0, total = total,
    clear_site = p.clear_site, started = util.now(), updated = util.now() }
  M.save_state()
  rednet.send(p.builder, { op = "job", from = "tmai", job = jid, name = plan.name, ox = plan.ox, sx = plan.sx,
    sy = plan.sy, sz = plan.sz, layers = plan.layers, mats = mats, clear_site = p.clear_site,
    from_layer = p.from_layer, player = player or p.player }, M.PROTO)
  util.log("I", "build: job %s plan %d -> turtle %d (%s)", jid, plan.id, p.builder, tostring(player))
  ui_event("build_status")
  return string.format("Строю «%s» (план %d) черепашкой %s: %d блоков%s.", plan.name, plan.id, bname(p.builder),
    plan.blocks, p.clear_site and ", с расчисткой площадки" or "")
end

local function send_all(op, builder)
  local n = 0
  for key, j in pairs(M.state().jobs) do
    local id = tonumber(key)
    if (not builder or id == builder) and ACTIVE[j.state] then
      rednet.send(id, { op = op, from = "tmai" }, M.PROTO)
      if op == "stop" then j.state = "stopping" end
      n = n + 1
    end
  end
  if builder and n == 0 and builders[builder] then
    rednet.send(builder, { op = op, from = "tmai" }, M.PROTO)
    n = 1
  end
  if op == "stop" then
    for c, p in pairs(pending) do
      if not builder or p.builder == builder then pending[c] = nil end
    end
  end
  M.save_state()
  ui_event("build_status")
  return n
end

-- Остановить стройку (черепашка вернётся к сундуку и выгрузит остатки). builder = nil — все.
function M.stop(builder) return send_all("stop", tonumber(builder)) end
function M.pause(builder) return send_all("pause", tonumber(builder)) end
function M.resume(builder) return send_all("resume", tonumber(builder)) end

-- ============================================================ поставка из МЭ
-- ME Bridge (AP 0.8.2a) exportItem(куда, фильтр) находит «куда» по имени периферии в СВОЕЙ проводной сети
-- (computer.getAvailablePeripheral): мост и сундук-склад черепашки должны быть в одной проводной сети
-- с компьютером ИИ (проводные модемы на мосту и на сундуке, кабель). Мост вплотную к компьютеру видит только
-- соседние с компьютером блоки — тогда доставка невозможна.
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

local function find_store(builder, b)
  local saved = M.state().stores[tostring(builder)]
  if saved and peripheral.isPresent and peripheral.isPresent(saved) then return saved end
  local want = agg(b.store)
  if next(want) == nil then return nil, "склад черепашки пуст — укажите имя сундука (chest), напр. minecraft:chest_3" end
  local found
  for _, name in ipairs(peripheral.getNames()) do
    if not SIDES[name] and peripheral.hasType(name, "inventory") then
      local ok, list = pcall(peripheral.call, name, "list")
      if ok and type(list) == "table" then
        local have = {}
        for _, it in pairs(list) do have[it.name] = (have[it.name] or 0) + it.count end
        local same = true
        for k, v in pairs(want) do if have[k] ~= v then same = false; break end end
        if same then for k, v in pairs(have) do if want[k] ~= v then same = false; break end end end
        if same then
          if found then return nil, "несколько сундуков в сети с таким же содержимым — укажите имя (chest)" end
          found = name
        end
      end
    end
  end
  if not found then
    return nil, "сундук черепашки не найден в проводной сети компьютера ИИ: поставьте на него проводной модем, " ..
      "соедините кабелем с сетью ME-моста, включите модем (ПКМ) и повторите (или укажите имя: chest)"
  end
  return found
end

function M.supply(args)
  local plan = M.get_plan(args.id)
  if not plan then return nil, "нет плана " .. tostring(args.id) end
  local builder = tonumber(args.builder)
  local b = builder and builders[builder]
  if not online(b) then return nil, "черепашка " .. tostring(builder) .. " не на связи" end
  local bridge = peripheral.find and peripheral.find("me_bridge")
  if not bridge then return nil, "ME-мост не подключён к компьютеру ИИ" end
  local bn = peripheral.getName(bridge)
  if SIDES[bn] then
    return nil, "ME-мост стоит вплотную к компьютеру — для доставки он должен быть в проводной сети вместе с сундуком " ..
      "черепашки (проводной модем на мосту и на сундуке, кабель)"
  end
  local okon, on = pcall(bridge.isOnline)
  if not okon or not on then return nil, "МЭ-сеть не отвечает" end
  local chk, err = M.check(plan.id, builder, tonumber(args.from_layer))
  if not chk then return nil, err end
  if #chk.missing == 0 and chk.fuel.coal_short == 0 then return { status = "nothing_missing", say = "На складе черепашки всё есть." } end
  local target = args.chest and tostring(args.chest) or nil
  if target then
    if not peripheral.hasType(target, "inventory") then return nil, "нет инвентаря «" .. target .. "» в сети компьютера ИИ" end
  else
    target, err = find_store(builder, b)
    if not target then return nil, err end
  end
  local delivered, absent, errors = {}, {}, {}
  local list = {}
  for _, m in ipairs(chk.missing) do list[#list + 1] = m end
  if chk.fuel.coal_short > 0 then list[#list + 1] = { item = "minecraft:coal", name = "уголь", count = chk.fuel.coal_short } end
  for _, m in ipairs(list) do
    local left, moved = m.count, 0
    for _ = 1, 64 do
      if left <= 0 then break end
      local ok, n, e = pcall(bridge.exportItem, target, { name = m.item, count = math.min(64, left) })
      if not ok then errors[#errors + 1] = m.item .. ": " .. tostring(n); break end
      n = tonumber(n) or 0
      if n <= 0 then
        if e and e ~= "ITEM_NOT_FOUND" then errors[#errors + 1] = m.item .. ": " .. tostring(e) end
        break
      end
      moved, left = moved + n, left - n
    end
    if moved > 0 then delivered[#delivered + 1] = { item = m.item, count = moved } end
    if left > 0 then
      local okc, craftable = pcall(bridge.isCraftable, { name = m.item })
      absent[#absent + 1] = { item = m.item, count = left, craftable = okc and craftable or false }
    end
    if #errors > 0 and errors[#errors]:find("INVENTORY_NOT_FOUND", 1, true) then
      return nil, "мост не видит сундук «" .. target .. "»: сундук и мост должны быть в одной проводной сети"
    end
  end
  if #delivered > 0 then
    M.state().stores[tostring(builder)] = target
    M.save_state()
    rednet.send(builder, { op = "recheck", from = "tmai" }, M.PROTO)
  end
  return { chest = target, delivered = delivered, not_in_me = absent, errors = #errors > 0 and errors or nil,
    say = #absent > 0 and "Части нет в МЭ: можно заказать автокрафт (me_craft) или добыть." or nil }
end

-- ============================================================ инструменты для нейросети
local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end
local S = function(d) return { type = "string", description = d } end
local N = function(d) return { type = "integer", description = d } end
local B = function(d) return { type = "boolean", description = d } end

local PLAN_SCHEMA = {
  type = "object",
  description = "план постройки (данные)",
  properties = {
    name = S("название по-русски"),
    materials = { type = "object", description = "ключ — одна латинская буква: {\"item\":\"minecraft:stone_bricks\",\"name\":\"каменные кирпичи\"}",
      additionalProperties = obj({ item = S("ID блока ns:id"), name = S("название по-русски") }, { "item" }) },
    parts = { type = "array", description = "фигуры по порядку, поздние перекрывают ранние",
      items = { type = "object", properties = { type = { type = "string",
        enum = { "fill", "box", "walls", "floor", "clear", "line", "cylinder", "roof", "layer" } } },
        required = { "type" } } },
  },
  required = { "name", "materials", "parts" },
}

local DEFS = {
  plan = {
    { name = "build_plan", description = "Создать (или заменить по id) план постройки для черепашки-строителя — ДАННЫЕ, не код. " ..
      "Перед первым планом прочитай pack.build (kb_read), если его нет в СПРАВКЕ. Оси: x вправо от черепашки, y вверх, z вперёд; " ..
      "(0,0,0) — клетка перед черепашкой на её уровне. Фигуры (у всех кроме clear/layer — m: ключ материала): " ..
      "fill|box|walls|floor|clear {from:[x,y,z], to:[x,y,z]}; line {from,to}; cylinder {center:[x,z], y:[y0,y1], r, hollow}; " ..
      "roof {from:[x0,y,z0], to:[x1,y,z1], style: gable|flat|pyramid, axis: x|z (конёк), half: ключ плиты, ends: ключ фронтонов}; " ..
      "layer {y, rows:[\"SS.S\",...] (rows[1] — z=0; '.' не трогать, '-' воздух), at:[x,z]}. " ..
      "Ответ: id, размер, блоки, смета, предупреждения; при ошибках исправь план и вызови снова.",
      parameters = obj({ plan = PLAN_SCHEMA, id = N("номер плана для замены (необязательно)") }, { "plan" }) },
    { name = "build_list", description = "Сохранённые планы построек: номер, название, размер x×y×z, слоёв, блоков.",
      parameters = obj({}) },
    { name = "build_show", description = "Показать план на экране ЛОЦМАНа (вкладка «Стройка»): вид сверху на слой. " ..
      "Вернёт смету и рисунок слоя.", parameters = obj({ id = N("номер плана"), layer = N("слой, 1 — нижний (необязательно)") }, { "id" }) },
    { name = "build_delete", description = "Удалить план по номеру.", parameters = obj({ id = N("номер плана") }, { "id" }) },
    { name = "build_builders", description = "Черепашки-строители на связи (программа tmbuild): id, метка, топливо, " ..
      "состояние, что в сундуке-складе. Нет ни одной — объясни игроку, как поставить (pack.build).", parameters = obj({}) },
  },
  work = {
    { name = "build_check", description = "Сверить смету плана со складом черепашки (сундук позади неё + её инвентарь): " ..
      "чего не хватает, сколько топлива нужно.",
      parameters = obj({ id = N("номер плана"), builder = N("id черепашки из build_builders"),
        from_layer = N("с какого слоя (необязательно)") }, { "id", "builder" }) },
    { name = "build_start", description = "Подготовить стройку: вернёт код; черепашка начнёт только после «да КОД» от игрока. " ..
      "clear_site=true — разрешить копать землю/камень/брёвна внутри площадки (траву и листву она убирает всегда). " ..
      "from_layer — продолжить с этого слоя (если нижние уже построены).",
      parameters = obj({ id = N("номер плана"), builder = N("id черепашки"), clear_site = B("расчистка площадки"),
        from_layer = N("с какого слоя, 1 = с начала") }, { "id", "builder" }) },
    { name = "build_status", description = "Ход строек: слой, процент, чего ждёт черепашка, что мешает.", parameters = obj({}) },
    { name = "build_stop", description = "Остановить стройку: черепашка вернётся к сундуку и выгрузит остатки. Без builder — все.",
      parameters = obj({ builder = N("id черепашки (необязательно)") }) },
    { name = "build_pause", description = "Пауза стройки (черепашка замрёт на месте) или продолжение (resume=true), в т.ч. после помехи.",
      parameters = obj({ builder = N("id черепашки (необязательно)"), resume = B("true — продолжить") }) },
  },
  supply = {
    { name = "build_supply", description = "Довезти недостающее для плана из МЭ-сети в сундук-склад черепашки (ME-мост и сундук " ..
      "в одной проводной сети). chest — имя сундука в сети, если не найдётся сам.",
      parameters = obj({ id = N("номер плана"), builder = N("id черепашки"), chest = S("имя периферии сундука, напр. minecraft:chest_3") },
        { "id", "builder" }) },
  },
}

local function has_jobs()
  for _, j in pairs(M.state().jobs) do if ACTIVE[j.state] then return true end end
  return false
end

-- Список инструментов стройки под текущее состояние (планы — всегда; работа — если есть черепашки).
function M.tool_defs(ctx)
  ctx = ctx or {}
  local list = {}
  for _, d in ipairs(DEFS.plan) do list[#list + 1] = d end
  local any = #M.list_builders() > 0
  if any or has_jobs() then for _, d in ipairs(DEFS.work) do list[#list + 1] = d end end
  local me = ctx.has_me
  if me == nil and peripheral and peripheral.find then me = peripheral.find("me_bridge") ~= nil end
  if any and me then for _, d in ipairs(DEFS.supply) do list[#list + 1] = d end end
  return list
end

-- Текстовый рисунок слоя для нейросети (rows[1] — z=0).
local function layer_ascii(plan, layer)
  local rows = rows_of(plan, layer - 1)
  local out = {}
  for z = 1, #rows do out[z] = rows[z] end
  return out
end

local function summary(c, warns)
  local mats = {}
  for _, m in ipairs(smeta(c)) do mats[#mats + 1] = { key = m.key, item = m.item, name = m.name, count = m.count } end
  local est = estimate(c)
  return { id = c.id, name = c.name, size = size_text(c), size_note = "x×y×z, x от " .. c.ox, layers = c.sy,
    blocks = c.blocks, materials = mats, fuel = est.fuel, minutes = est.minutes,
    warnings = (warns and #warns > 0) and warns or nil }
end

local function status_list()
  local out = {}
  for key, j in pairs(M.state().jobs) do
    local b = builders[tonumber(key)]
    out[#out + 1] = { builder = tonumber(key), plan = j.plan, name = j.name, player = j.player, state = j.state,
      layer = j.layer, layers = j.layers, done = j.done, total = j.total, skipped = j.skipped,
      percent = math.floor(100 * (j.done or 0) / math.max(1, j.total or 1)),
      missing = j.missing, blocked = j.blocked, online = online(b), fuel = b and b.fuel }
  end
  table.sort(out, function(a, b) return a.builder < b.builder end)
  for c, p in pairs(pending) do
    out[#out + 1] = { code = c, plan = p.plan, builder = p.builder, state = "awaiting_confirmation" }
  end
  return out
end

local function top(list, n)
  local out = {}
  for i, it in ipairs(list or {}) do
    if i > n then break end
    out[i] = it
  end
  return out
end

-- Выполнить инструмент стройки. ctx = { player = ник спрашивающего, has_me = ... }
function M.run_tool(name, a, ctx)
  a = type(a) == "table" and a or {}
  ctx = ctx or {}
  if name == "build_plan" then
    local plan = a.plan
    if type(plan) == "string" then plan = json.decode(plan) end
    local c, errs, warns = M.save_plan(plan, a.id, ctx.player)
    if not c then
      return { ok = false, errors = errs, warnings = (warns and #warns > 0) and warns or nil,
        hint = "Исправь план и вызови build_plan снова (формат — pack.build)." }
    end
    M.select(c.id, 1)
    local r = summary(c, warns)
    r.ok = true
    r.say = "План " .. c.id .. " «" .. c.name .. "» сохранён и выведен на экран."
    return r
  elseif name == "build_list" then
    local l = M.list_plans()
    if #l == 0 then return "планов нет — составь новый (build_plan)" end
    return l
  elseif name == "build_show" then
    local p, layer = M.select(a.id, a.layer)
    if not p then return "отказ: " .. tostring(layer) end
    local r = summary(p)
    r.layer, r.rows_from_z0 = layer, layer_ascii(p, layer)
    r.say = "План " .. p.id .. " на экране, слой " .. layer .. " из " .. p.sy .. "."
    return r
  elseif name == "build_delete" then
    local ok, e = M.delete_plan(a.id)
    return ok and ("план " .. tostring(a.id) .. " удалён") or ("отказ: " .. tostring(e))
  elseif name == "build_builders" then
    local out = {}
    for _, id in ipairs(M.list_builders()) do
      local b = builders[id]
      local j = job_of(id)
      out[#out + 1] = { id = id, label = b.label, fuel = b.fuel, fuel_limit = b.fuel_limit, state = b.state or "idle",
        job = (j and ACTIVE[j.state]) and (j.name .. " (план " .. tostring(j.plan) .. ")") or nil,
        has_pickaxe = b.tool, store = top(b.store, 20), store_slots = b.store_size, inventory = top(b.inv, 16) }
    end
    if #out == 0 then
      return "черепашек-строителей на связи нет: на черепашке с модемом запустить tmbuild (или метка TM-BUILD-1 и перезагрузка), " ..
        "сундук-склад — позади неё (pack.build)"
    end
    return out
  elseif name == "build_check" then
    local r, e = M.check(a.id, a.builder, tonumber(a.from_layer))
    return r or ("отказ: " .. tostring(e))
  elseif name == "build_start" then
    local r, e = M.start(a, ctx.player)
    return r or ("отказ: " .. tostring(e))
  elseif name == "build_status" then
    local l = status_list()
    if #l == 0 then return "строек нет" end
    return l
  elseif name == "build_stop" then
    return "остановлено строек: " .. M.stop(a.builder)
  elseif name == "build_pause" then
    if a.resume then return "продолжено строек: " .. M.resume(a.builder) end
    return "на паузе строек: " .. M.pause(a.builder)
  elseif name == "build_supply" then
    local r, e = M.supply(a)
    return r or ("отказ: " .. tostring(e))
  end
  return "нет такого инструмента"
end

-- ============================================================ экран
-- Краткое состояние строек для экрана (UTF-8; перед выводом — text.cc).
function M.status_lines()
  local out = {}
  local keys = {}
  for key in pairs(M.state().jobs) do keys[#keys + 1] = tonumber(key) end
  table.sort(keys)
  for _, id in ipairs(keys) do
    local j = job_of(id)
    local b = builders[id]
    local s
    if j.state == "building" or j.state == "sent" then
      s = string.format("слой %s/%s, %d%%", tostring(j.layer or "?"), tostring(j.layers or "?"),
        math.floor(100 * (j.done or 0) / math.max(1, j.total or 1)))
    elseif j.state == "waiting" then s = "ждёт: " .. (missing_text(j, j.missing) ~= "" and missing_text(j, j.missing) or "топливо")
    elseif j.state == "blocked" then s = "мешает " .. tostring(j.blocked and j.blocked.block or "?")
    elseif j.state == "paused" then s = "пауза"
    elseif j.state == "done" then s = "готово"
    elseif j.state == "stopped" or j.state == "stopping" then s = "остановлена"
    elseif j.state == "lost" then s = "потеряла ориентацию"
    elseif j.state == "error" then s = "ошибка"
    else s = tostring(j.state) end
    if ACTIVE[j.state] and not online(b) then s = s .. " (нет связи)" end
    out[#out + 1] = "#" .. id .. " «" .. tostring(j.name) .. "»: " .. s
  end
  for c, p in pairs(pending) do
    out[#out + 1] = "ждёт «да " .. c .. "»: план " .. p.plan .. " → #" .. p.builder
  end
  if #out == 0 then out[1] = "строек нет" end
  return out
end

-- Активная стройка этого плана (для подсветки построенного): job | nil
local function job_for_plan(id)
  for _, j in pairs(M.state().jobs) do
    if j.plan == id and (j.state == "building" or j.state == "waiting" or j.state == "paused" or j.state == "blocked"
      or j.state == "sent") then return j end
  end
  return nil
end

local function blit_or_write(win, s, fg, bg)
  if win.blit then win.blit(s, fg, bg)
  else
    local i = 1
    for c in s:gmatch(".") do
      local hf, hb = fg:sub(i, i), bg:sub(i, i)
      for v, h in pairs(HEX) do
        if h == hf then win.setTextColor(v) end
        if h == hb then win.setBackgroundColor(v) end
      end
      win.write(c)
      i = i + 1
    end
  end
end

local function write_at(win, x, y, s, color, w)
  win.setCursorPos(x, y)
  if color then win.setTextColor(color) end
  win.write(tcc(w and fit(s, w) or s))
end

-- Нарисовать слой плана сверху на term-подобный объект (term, монитор, window).
--   id, layer — план и слой (1 — нижний); nil — выбранные (build_show / build_plan).
--   opts.scroll_x, opts.scroll_z — прокрутка в клетках (1:1); без них большой план ужимается масштабом.
--   opts.legend = false — без легенды; opts.progress = false — без подсветки построенного.
-- Возвращает { id, layer, layers, scale, cell_w, scroll_x, scroll_z, max_scroll_x, max_scroll_z }.
function M.render(win, id, layer, opts)
  opts = opts or {}
  local W, H = win.getSize()
  win.setBackgroundColor(C.black)
  win.setTextColor(C.white)
  win.clear()
  local sid, slayer = M.selected()
  if id == nil then id, layer = sid, layer or slayer end
  local plan = id and M.get_plan(id)
  if not plan then
    local lines = wrap(id and ("План " .. tostring(id) .. " не найден.") or
      "Планов нет. Скажите: «Лоцман, построй дом 7×5 с окнами».", W)
    for i, l in ipairs(lines) do
      if i > H then break end
      write_at(win, 1, i, l, i == 1 and C.yellow or C.lightGray, W)
    end
    return { layers = 0 }
  end
  if id == sid and layer == nil then layer = slayer end
  layer = math.floor(tonumber(layer) or 1)
  if layer < 1 then layer = 1 elseif layer > plan.sy then layer = plan.sy end
  local y = layer - 1
  -- заголовок
  local title = "План " .. plan.id .. ": " .. plan.name .. " — слой " .. layer .. "/" .. plan.sy
  if tlen(title) > W then
    local tail = " " .. layer .. "/" .. plan.sy
    title = fit("П" .. plan.id .. " " .. plan.name, math.max(1, W - tlen(tail))) .. tail
  end
  write_at(win, 1, 1, title, C.yellow, W)
  -- материалы слоя
  local rows = rows_of(plan, y)
  local keys, lcount = {}, {}
  for _, row in ipairs(rows) do
    for c in row:gmatch("%a") do
      if not lcount[c] then keys[#keys + 1] = c end
      lcount[c] = (lcount[c] or 0) + 1
    end
  end
  table.sort(keys)
  local all_keys = {}
  for k in pairs(plan.materials) do all_keys[#all_keys + 1] = k end
  table.sort(all_keys)
  local colors_of = {}
  for i, k in ipairs(all_keys) do colors_of[k] = color_of(plan.materials[k].item, i) end
  -- раскладка: легенда справа (широкое окно) или снизу (узкое)
  local legend = opts.legend ~= false
  local side = legend and W >= 36
  local lw = 0
  if side then
    -- легенде — всё, что не нужно сетке (сетка: 2 символа на клетку, если влезает), от 14 до 30 символов
    local room = W - 14 - 1
    local need = (plan.sx * 2 <= room and plan.sz <= H - 1) and plan.sx * 2 or math.min(plan.sx, room)
    lw = math.max(14, math.min(30, W - need - 1))
  end
  local gx0, gy0 = 1, 2
  local gw = side and (W - lw - 1) or W
  local bottom = 0
  if legend and not side then
    local len = -1
    for _, k in ipairs(keys) do len = len + 2 + #tostring(lcount[k]) end
    bottom = (len <= W) and 1 or 2
    if #keys == 0 then bottom = 0 end
  end
  local gh = H - 1 - bottom
  if gh < 1 or gw < 1 then return { id = plan.id, layer = layer, layers = plan.sy } end
  -- прогресс стройки
  local job = opts.progress ~= false and job_for_plan(plan.id) or nil
  local built = {}           -- индекс клетки -> true (только для текущего слоя стройки)
  local all_built, none_built = false, job ~= nil
  if job then
    local jl = tonumber(job.layer) or 1
    if y < jl - 1 then all_built, none_built = true, false
    elseif y == jl - 1 then
      none_built = false
      local order = cell_order(plan, y)
      for i = 1, math.min((tonumber(job.cell) or 1) - 1, #order) do
        built[(order[i].z) * plan.sx + (order[i].x - plan.ox)] = true
      end
    end
  end
  local function is_built(x, z)
    if not job then return true end
    if all_built then return true end
    if none_built then return false end
    return built[z * plan.sx + (x - plan.ox)] == true
  end
  -- масштаб / прокрутка
  local scale, cw = 1, 1
  local scrolled = opts.scroll_x ~= nil or opts.scroll_z ~= nil
  if not scrolled and (plan.sx > gw or plan.sz > gh) then
    scale = math.max(math.ceil(plan.sx / gw), math.ceil(plan.sz / gh))
  end
  if scale == 1 and plan.sx * 2 <= gw then cw = 2 end
  local vw = math.min(math.ceil(plan.sx / scale), math.floor(gw / cw))
  local vh = math.min(math.ceil(plan.sz / scale), gh)
  local max_sx = math.max(0, plan.sx - vw)
  local max_sz = math.max(0, plan.sz - vh)
  local sx0 = scale == 1 and math.max(0, math.min(math.floor(tonumber(opts.scroll_x) or 0), max_sx)) or 0
  local sz0 = scale == 1 and math.max(0, math.min(math.floor(tonumber(opts.scroll_z) or 0), max_sz)) or 0
  local offx = gx0 + math.floor((gw - vw * cw) / 2)
  local offy = gy0 + math.floor((gh - vh) / 2)
  -- позиция черепашки (если она над этим слоем)
  local tpos = job and type(job.pos) == "table" and job.pos or nil
  local tx, tz
  if tpos and tonumber(tpos[2]) == y + 1 then tx, tz = tonumber(tpos[1]), tonumber(tpos[3]) end
  for r = 0, vh - 1 do
    -- верх экрана — дальний край (большие z), низ — ближний к черепашке
    local cz0 = sz0 + (vh - 1 - r) * scale
    local s, fg, bg = {}, {}, {}
    for col = 0, vw - 1 do
      local cx0 = sx0 + col * scale
      local ch, b
      if scale == 1 then
        local row = rows[cz0 + 1] or ""
        ch = row:sub(cx0 + 1, cx0 + 1)
        if ch == "" then ch = "." end
        b = is_built(plan.ox + cx0, cz0)
      else
        local cnt, nb, nmat, best, bestn, clear = {}, 0, 0, nil, 0, false
        for dz = 0, scale - 1 do
          local row = rows[cz0 + dz + 1] or ""
          for dx = 0, scale - 1 do
            local c = row:sub(cx0 + dx + 1, cx0 + dx + 1)
            if c:match("%a") then
              cnt[c] = (cnt[c] or 0) + 1
              nmat = nmat + 1
              if is_built(plan.ox + cx0 + dx, cz0 + dz) then nb = nb + 1 end
              if cnt[c] > bestn then best, bestn = c, cnt[c] end
            elseif c == "-" then clear = true end
          end
        end
        ch = best or (clear and "-" or ".")
        b = nmat > 0 and nb * 2 >= nmat
      end
      local glyph, f, k = " ", C.white, C.black
      if ch == "-" then glyph, f = "-", C.gray
      elseif ch ~= "." then
        local col_c = colors_of[ch] or C.white
        glyph = ch
        if b then k = col_c; f = DARK[col_c] and C.white or C.black
        else f = col_c end
      end
      if tx and scale == 1 and plan.ox + cx0 == tx and cz0 == tz then glyph, f, k = "@", C.yellow, C.black end
      s[#s + 1] = cw == 2 and (glyph .. " ") or glyph
      fg[#fg + 1] = string.rep(HEX[f], cw)
      bg[#bg + 1] = string.rep(HEX[k], cw)
    end
    win.setCursorPos(offx, offy + r)
    blit_or_write(win, table.concat(s), table.concat(fg), table.concat(bg))
  end
  -- где стоит черепашка (ниже ближнего края, x = 0)
  if scale == 1 and sz0 == 0 and offy + vh <= gy0 + gh - 1 then
    local col = (0 - plan.ox) - sx0
    if col >= 0 and col < vw then
      win.setCursorPos(offx + col * cw, offy + vh)
      blit_or_write(win, "^", HEX[C.yellow], HEX[C.black])
    end
  end
  win.setBackgroundColor(C.black)
  -- легенда
  if legend and side then
    local lx, ly = W - lw + 1, 2
    local room = H - 2                       -- строки 2..H-1; последняя — примечание
    for i, k in ipairs(keys) do
      if #keys > room and i == room then write_at(win, lx, ly, "+" .. (#keys - i + 1), C.lightGray, lw); break end
      win.setCursorPos(lx, ly)
      local c = colors_of[k] or C.white
      blit_or_write(win, k, HEX[DARK[c] and C.white or C.black], HEX[c])
      win.setBackgroundColor(C.black)
      local m = plan.materials[k]
      write_at(win, lx + 1, ly, " " .. lcount[k] .. "/" .. tostring(plan.counts[k] or 0) .. " " .. (m and m.name or "?"),
        C.white, lw - 1)
      ly = ly + 1
    end
    do
      local note = scale > 1 and ("масштаб 1:" .. scale) or ((max_sx > 0 or max_sz > 0) and "прокрутка" or nil)
      if job then note = (note and (note .. ", ") or "") .. "строится " .. math.floor(100 * (job.done or 0) / math.max(1, job.total or 1)) .. "%" end
      if note then write_at(win, lx, H, note, C.lightGray, lw) end
    end
  elseif legend and bottom > 0 then
    local x, yy = 1, H - bottom + 1
    for _, k in ipairs(keys) do
      local piece = tostring(lcount[k])
      if x + #piece > W then
        yy = yy + 1; x = 1
        if yy > H then break end
      end
      win.setCursorPos(x, yy)
      local c = colors_of[k] or C.white
      blit_or_write(win, k, HEX[DARK[c] and C.white or C.black], HEX[c])
      win.setBackgroundColor(C.black)
      write_at(win, x + 1, yy, piece, C.white)
      x = x + 2 + #piece
    end
  end
  return { id = plan.id, layer = layer, layers = plan.sy, scale = scale, cell_w = cw, scroll_x = sx0, scroll_z = sz0,
    max_scroll_x = max_sx, max_scroll_z = max_sz }
end

return M
