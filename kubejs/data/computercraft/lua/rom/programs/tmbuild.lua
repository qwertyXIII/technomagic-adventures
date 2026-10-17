-- tmbuild — черепашка-строитель ЛОЦМАНа («прораб»). Строит по плану, который ЛОЦМАН присылает по rednet
-- (протокол "tmai_build"), из блоков сундука-склада ПОЗАДИ черепашки.
--   tmbuild            — ждать заданий; незаконченная стройка продолжается сама
--   tmbuild startup    — то же + автозапуск при включении (после перезагрузки/выгрузки чанка стройка продолжится)
--   tmbuild nostartup  — убрать автозапуск
--   tmbuild reset      — забыть текущую стройку и компьютер-владелец
-- Метка TM-BUILD… (label set TM-BUILD-1) — автозапуск из ROM, startup-файл не нужен.
-- Нужны: модем (беспроводной/эндер или проводной); кирка — чтобы убирать листву и расчищать площадку.
-- Отказывается работать на компьютерах TM-AI/TM-NAV и на командных.
--
-- Координаты задания: черепашка в (0,0,-1) лицом к +z, сундук в (0,0,-2); x — вправо, y — вверх, z — вперёд.
-- Строит слоями снизу вверх, двигаясь НАД слоем и ставя блоки вниз (placeDown), змейкой по рядам.
-- К сундуку и обратно — поверх постройки. Внутри площадки убирает траву/листву/снег; землю, камень, брёвна —
-- только с разрешения clear_site и только в клетках постройки и над ними; снаружи площадки не ломает ничего
-- (обходит сверху).
-- Позиция — счётом ходов (без GPS). Состояние пишется на диск ДО и ПОСЛЕ каждого хода и поворота; если
-- перезагрузка случилась между ходом и записью, ход распознаётся по топливу (need_fuel = true в сборке),
-- поворот — по сундуку (на старте) или пробным возвратом к сундуку (recover / probe_home).
local args = { ... }
local LIB = args[1] == "__lib"          -- офлайн-тесты: вернуть внутренности, не запуская
local label = os.getComputerLabel() or ""
local json = require("tmai.json")
local text = require("tmai.text")       -- кириллица на экране (шрифт сборки, CP1251)
local function say(s) print(text.cc(s)) end
local function warn(s) printError(text.cc(s)) end
if not LIB then
  if commands or label == "TM-AI" or label == "TM-NAV" then
    warn("tmbuild: здесь нельзя (компьютер ЛОЦМАНа, штурманский или командный)"); return
  end
  if not turtle then warn("tmbuild: программа только для черепашки"); return end
end

local PROTO = "tmai_build"
local VERSION = 1
local DIR = "/tmbuild"
local STATE = DIR .. "/state.json"
local PLAN = DIR .. "/plan.json"
local STARTUP = "/startup/tmbuild.lua"
local HELLO_EVERY = 30                 -- «я на связи», с
local RETRY_EVERY = 30                 -- повторная проверка склада/помехи, с
local PROGRESS_EVERY = 20              -- отчёт о ходе, с
local FUEL_MARGIN = 24                 -- запас топлива сверх дороги туда и обратно

-- ============================================================ командная строка
if not LIB then
  if args[1] == "nostartup" then
    if fs.exists(STARTUP) then fs.delete(STARTUP) end
    say("tmbuild: автозапуск убран")
    return
  elseif args[1] == "reset" then
    for _, p in ipairs({ STATE, STATE .. ".tmp", PLAN, PLAN .. ".tmp" }) do if fs.exists(p) then fs.delete(p) end end
    settings.unset("tmbuild.owner"); settings.save()
    say("tmbuild: стройка и компьютер-владелец забыты")
    return
  elseif args[1] == "startup" then
    if fs.exists("/startup") and not fs.isDir("/startup") then
      warn("tmbuild: /startup — файл; переименуйте его в /startup.lua"); return
    end
    fs.makeDir("/startup")
    local h = fs.open(STARTUP, "w")
    h.write('-- LOCMAN builder autostart (remove: tmbuild nostartup)\n' ..
      '-- with label TM-BUILD* it is started by ROM autorun instead\n' ..
      'if not (os.getComputerLabel() or ""):match("^TM%-BUILD") then\n' ..
      '  if multishell then shell.openTab("tmbuild") else shell.run("tmbuild") end\n' ..
      'end\n')
    h.close()
    say("tmbuild: автозапуск включён (" .. STARTUP .. ")")
  end
  if _G.__tmbuild_running then warn("tmbuild: уже запущена"); return end
end

-- ============================================================ состояние
local st            -- { job, player, clear_site, pos={x,y,z}, dir, layer, cell, start_layer, phase, pending, probe,
                    --   alias, skipped, paused, error }
local plan          -- { job, name, ox, sx, sy, sz, layers (RLE), mats = { K = item } }
local plan_items = {}
local rows, cells_cache = {}, {}
local inv = {}      -- слот -> { name, count }
local store = { list = {}, size = 0 }   -- последний снимок сундука
local ctl = { pause = false, stop = false, resume = false }
local owner = settings.get("tmbuild.owner")
local NODIG = false
local STOP, LOST = {}, {}               -- уникальные значения error() для «стоп» и «потеряла ориентацию»
local last_progress, last_block_sig = -1000, nil

local function read(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

-- Запись через временный файл: обрыв посреди записи не портит прежнее состояние.
local function write_atomic(path, data)
  if not fs.exists(DIR) then fs.makeDir(DIR) end
  local tmp = path .. ".tmp"
  local h = fs.open(tmp, "w")
  h.write(data)
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

local function load_json(path)
  for _, p in ipairs({ path, path .. ".tmp" }) do
    local s = read(p)
    local v = s and json.decode(s)
    if type(v) == "table" then return v end
  end
  return nil
end

local function save() if st then write_atomic(STATE, json.encode(st)) end end

local function send(m)
  m.from, m.owner = "tmbuild", owner
  if owner then rednet.send(owner, m, PROTO) end
end

local function wake() os.queueEvent("tmbuild_wake") end

-- ============================================================ план
local function unrle(s) return (s:gsub("(%d*)(%D)", function(k, c) return c:rep(tonumber(k) or 1) end)) end

local function row(y, z)
  local ly = rows[y + 1]
  if not ly then
    ly = {}
    for i, r in ipairs(plan.layers[y + 1] or {}) do ly[i] = unrle(r) end
    rows[y + 1] = ly
  end
  return ly[z + 1] or ""
end

local function cell_at(x, y, z)
  if y < 0 or y >= plan.sy or z < 0 or z >= plan.sz then return nil end
  local i = x - plan.ox + 1
  if i < 1 or i > plan.sx then return nil end
  local c = row(y, z):sub(i, i)
  if c == "" or c == "." then return nil end
  return c
end

-- Клетки слоя в порядке обхода (так же считает build.lua, cell_order): змейка по рядам z, x туда-обратно.
local function layer_cells(y)
  if cells_cache[y] then return cells_cache[y] end
  local list = {}
  for z = 0, plan.sz - 1 do
    local r = row(y, z)
    local a, b, s = 1, plan.sx, 1
    if z % 2 == 1 then a, b, s = plan.sx, 1, -1 end
    for i = a, b, s do
      local ch = r:sub(i, i)
      if ch ~= "." and ch ~= "" then list[#list + 1] = { x = plan.ox + i - 1, z = z, ch = ch } end
    end
  end
  cells_cache[y] = list
  return list
end

local function in_box(x, z) return x >= plan.ox and x < plan.ox + plan.sx and z >= 0 and z < plan.sz end
-- «площадка»: объём плана и один слой над ним (там черепашка ходит, ставя верхний слой)
local function in_volume(x, y, z) return in_box(x, z) and y >= 0 and y <= plan.sy end
local function alt() return plan.sy end

-- клетка постройки или место над ней (там черепашка проходит, ставя блок) — тут можно срезать землю/камень
local function plan_spot(x, y, z) return cell_at(x, y, z) ~= nil or cell_at(x, y - 1, z) ~= nil end

local function is_own(x, y, z, name)
  local c = cell_at(x, y, z)
  if not c or c == "-" then return false end
  local item = plan.mats[c]
  return item == name or (st.alias[item] ~= nil and st.alias[item] == name)
end

local function done_count()
  local n = 0
  for y = st.start_layer or 0, st.layer - 1 do n = n + #layer_cells(y) end
  return n + st.cell - 1
end
local function total_count()
  local n = 0
  for y = st.start_layer or 0, plan.sy - 1 do n = n + #layer_cells(y) end
  return n
end

-- ============================================================ блоки вокруг: что можно убрать
local SOFT_TAGS = { "minecraft:replaceable", "minecraft:replaceable_by_trees", "minecraft:leaves", "minecraft:flowers",
  "minecraft:small_flowers", "minecraft:saplings", "minecraft:crops", "minecraft:cave_vines" }
local SOFT_NAMES = { "short_grass$", "tall_grass$", "^minecraft:grass$", "fern$", "dead_bush$", "_flower$", "tulip$",
  "poppy$", "dandelion$", "orchid$", "allium$", "bluet$", "daisy$", "cornflower$", "lily_of_the_valley$",
  "rose_bush$", "peony$", "lilac$", "sunflower$", "berry_bush$", "vine$", "vines$", "vines_plant$", "leaves$",
  "sapling$", "mushroom$", "seagrass$", "kelp$", "kelp_plant$", "^minecraft:snow$", "moss_carpet$", "lichen$",
  "sugar_cane$", "roots$", "sprouts$", "^minecraft:water$", "^minecraft:lava$", "bubble_column$" }
local NATURAL_TAGS = { "minecraft:dirt", "minecraft:base_stone_overworld", "minecraft:base_stone_nether",
  "minecraft:sand", "minecraft:logs", "minecraft:snow", "minecraft:ice", "minecraft:sculk_replaceable",
  "minecraft:stone_ore_replaceables", "minecraft:deepslate_ore_replaceables", "minecraft:mushroom_grow_block",
  "c:ores", "c:gravels", "c:sands" }
local NATURAL_NAMES = { "gravel$", "clay$", "^minecraft:mud$", "^minecraft:sandstone$", "^minecraft:red_sandstone$",
  "mycelium$", "podzol$", "netherrack$", "^minecraft:end_stone$", "calcite$", "^minecraft:tuff$", "_ore$",
  "^minecraft:stone$", "^minecraft:granite$", "^minecraft:diorite$", "^minecraft:andesite$", "^minecraft:deepslate$",
  "moss_block$", "snow_block$", "ice$", "_log$", "mushroom_block$", "mushroom_stem$", "dripstone_block$",
  "grass_block$", "dirt$", "^minecraft:dirt_path$" }
local LIQUID = { ["minecraft:water"] = true, ["minecraft:lava"] = true }

-- "soft" — трава, цветы, листва, снег (убирать всегда, внутри площадки); "natural" — земля, камень, брёвна
-- (только с clear_site); "foreign" — всё остальное (постройки игроков) — не трогать никогда.
local function classify(b)
  if type(b) ~= "table" or type(b.name) ~= "string" then return "foreign" end
  local tags = type(b.tags) == "table" and b.tags or {}
  for _, t in ipairs(SOFT_TAGS) do if tags[t] then return "soft" end end
  for _, p in ipairs(SOFT_NAMES) do if b.name:find(p) then return "soft" end end
  for _, t in ipairs(NATURAL_TAGS) do if tags[t] then return "natural" end end
  for _, p in ipairs(NATURAL_NAMES) do if b.name:find(p) then return "natural" end end
  return "foreign"
end

-- ============================================================ движение с записью состояния
local DX = { [0] = 0, 1, 0, -1 }        -- dir: 0 = +z (вперёд), 1 = +x (вправо), 2 = -z, 3 = -x
local DZ = { [0] = 1, 0, -1, 0 }
local SIDE_BY_REL = { [0] = "front", "right", "back", "left" }

local function apply_move(d, dir)
  local p = st.pos
  if d == "u" then p.y = p.y + 1
  elseif d == "d" then p.y = p.y - 1
  else p.x, p.z = p.x + DX[dir], p.z + DZ[dir] end
end

local function step(d)
  st.pending = { kind = "move", d = d, dir = st.dir, fuel = turtle.getFuelLevel() }
  save()
  local ok, err
  if d == "u" then ok, err = turtle.up()
  elseif d == "d" then ok, err = turtle.down()
  else ok, err = turtle.forward() end
  if ok then apply_move(d, st.dir) end
  st.pending = nil
  save()
  return ok, err
end

local function turn(right)
  local to = right and (st.dir + 1) % 4 or (st.dir + 3) % 4
  st.pending = { kind = "turn", from = st.dir, to = to }
  save()
  if right then turtle.turnRight() else turtle.turnLeft() end
  st.dir = to
  st.pending = nil
  save()
end

local function face(d)
  local diff = (d - st.dir) % 4
  if diff == 1 then turn(true)
  elseif diff == 3 then turn(false)
  elseif diff == 2 then turn(true); turn(true) end
end

-- Сундук на месте? Проверяем, повернувшись к нему: сторону с модемом черепашка как периферию не видит.
local function chest_ok()
  face(2)
  return peripheral.hasType("front", "inventory") == true
end

local function inspect(d)
  if d == "u" then return turtle.inspectUp() elseif d == "d" then return turtle.inspectDown() end
  return turtle.inspect()
end

-- Копать с повтором (гравий и песок досыпаются сверху).
local function dig(d)
  local f = d == "u" and turtle.digUp or (d == "d" and turtle.digDown or turtle.dig)
  local det = d == "u" and turtle.detectUp or (d == "d" and turtle.detectDown or turtle.detect)
  local ok, err = f()
  if not ok then return false, err end
  for _ = 1, 10 do
    if not det() then break end
    if not f() then break end
  end
  return true
end

local function target_of(d)
  local p = st.pos
  if d == "u" then return p.x, p.y + 1, p.z elseif d == "d" then return p.x, p.y - 1, p.z end
  return p.x + DX[st.dir], p.y, p.z + DZ[st.dir]
end

local function report_blocked(reason, name, x, y, z)
  local sig = reason .. tostring(name) .. "@" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
  if sig == last_block_sig then return end
  last_block_sig = sig
  send({ op = "blocked", job = st.job, reason = reason, block = name, at = { x, y, z } })
end

local pause_point     -- объявлена ниже (нужна go для ожидания существ)

-- Один ход с обработкой помех. -> true | false, причина, блок, x, y, z
-- причины: fuel, limit, own (блок плана), natural (земля/камень без clear_site), block (чужой блок),
-- outside (помеха вне площадки — не ломаем), nodig (нечем копать), entity (существо не уходит)
local function go(d)
  local waited = 0
  while true do
    local ok, err = step(d)
    if ok then return true end
    err = tostring(err)
    if err:find("fuel") then return false, "fuel" end
    if err:find("high") or err:find("low") or err:find("world") or err:find("protected") or err:find("border") then
      return false, "limit", err
    end
    local tx, ty, tz = target_of(d)
    local has, b = inspect(d)
    if has and type(b) == "table" then
      if NODIG then return false, "block", b.name, tx, ty, tz end
      if not in_volume(tx, ty, tz) then return false, "outside", b.name, tx, ty, tz end
      if is_own(tx, ty, tz, b.name) then return false, "own", b.name, tx, ty, tz end
      local cls = classify(b)
      if cls == "soft" or (cls == "natural" and st.clear_site and plan_spot(tx, ty, tz)) then
        local dok, derr = dig(d)
        if not dok then return false, "nodig", b.name .. " (" .. tostring(derr) .. ")", tx, ty, tz end
      else
        return false, cls == "natural" and "natural" or "block", b.name, tx, ty, tz
      end
    else
      -- не блок: игрок или моб — подождать
      waited = waited + 1
      if waited == 10 then report_blocked("entity", "entity", tx, ty, tz) end
      if waited > 120 then return false, "entity", "entity", tx, ty, tz end
      pause_point()
      sleep(0.5)
    end
  end
end

local function vertical(ty)
  while st.pos.y ~= ty do
    local ok, why, a, b, c, d = go(st.pos.y < ty and "u" or "d")
    if not ok then return false, why, a, b, c, d end
  end
  return true
end

local function axis_dir(axis, delta)
  if axis == "x" then return delta > 0 and 1 or 3 end
  return delta > 0 and 0 or 2
end

-- По прямой в плоскости (внутри площадки): сначала одна ось, потом другая.
local function planar(x, z, xfirst)
  for pass = 1, 2 do
    local axis = ((pass == 1) == xfirst) and "x" or "z"
    local cur = axis == "x" and st.pos.x or st.pos.z
    local goal = axis == "x" and x or z
    if cur ~= goal then
      face(axis_dir(axis, goal - cur))
      for _ = 1, math.abs(goal - cur) do
        local ok, why, a, b, c, d = go("f")
        if not ok then return false, why, a, b, c, d end
      end
    end
  end
  return true
end

-- Полёт на текущей высоте; помеха — обойти по другой оси или подняться выше.
local function fly(x, z)
  local rises = 0
  while st.pos.x ~= x or st.pos.z ~= z do
    local moved, why, a, b, c, d = false
    -- из-за сундука (z < 0) — сначала вперёд, на площадку; иначе сначала по x
    local axes = st.pos.z < 0 and { "z", "x" } or { "x", "z" }
    for _, axis in ipairs(axes) do
      local delta = axis == "x" and (x - st.pos.x) or (z - st.pos.z)
      if delta ~= 0 and not moved then
        face(axis_dir(axis, delta))
        local ok
        ok, why, a, b, c, d = go("f")
        if ok then moved = true
        elseif why == "fuel" or why == "limit" or why == "entity" or why == "nodig" then return false, why, a, b, c, d end
      end
    end
    if not moved then
      if rises >= 16 then return false, why, a, b, c, d end
      local ok, w2, a2, b2, c2, d2 = go("u")
      if not ok then return false, w2, a2, b2, c2, d2 end
      rises = rises + 1
    end
  end
  return true
end

-- Дойти до точки (x, ty, z). Внутри площадки и не ниже — напрямую; иначе — вверх над постройкой, полёт, спуск.
local function travel(x, ty, z)
  local p = st.pos
  if p.x == x and p.y == ty and p.z == z then return true end
  if p.x == x and p.z == z and (ty > p.y or not in_box(x, z)) and vertical(ty) then return true end
  if in_box(p.x, p.z) and in_box(x, z) and ty >= p.y and p.y >= 0 then
    if vertical(ty) and (planar(x, z, true) or planar(x, z, false)) then return true end
  end
  local ok, why, a, b, c, d = vertical(math.max(alt(), st.pos.y))
  if not ok then return false, why, a, b, c, d end
  ok, why, a, b, c, d = fly(x, z)
  if not ok then return false, why, a, b, c, d end
  return vertical(ty)
end

local function fuel_level()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end
-- ходов от точки до дома (вверх над постройкой, полёт, вниз)
local function cost_home(x, y, z) return math.max(0, alt() - y) + math.abs(x) + math.abs(z + 1) + alt() end
local function cost_to(x, y, z)
  local p = st.pos
  if in_box(p.x, p.z) and in_box(x, z) and y >= p.y then return (y - p.y) + math.abs(x - p.x) + math.abs(z - p.z) end
  return math.max(0, alt() - p.y) + math.abs(x - p.x) + math.abs(z - p.z) + math.max(0, alt() - y)
end
local function fuel_ok(x, y, z) return fuel_level() >= cost_to(x, y, z) + cost_home(x, y, z) + FUEL_MARGIN end

-- ============================================================ инвентарь и сундук
local function scan()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    inv[s] = d and { name = d.name, count = d.count } or nil
  end
end
local function find_slot(name)
  for s = 1, 16 do local it = inv[s]; if it and it.name == name and it.count > 0 then return s end end
  return nil
end
local function count_of(name)
  local n = 0
  for s = 1, 16 do local it = inv[s]; if it and it.name == name then n = n + it.count end end
  return n
end
local function empty_slot() for s = 1, 16 do if not inv[s] then return s end end return nil end
local function slot_for(name)
  for s = 1, 16 do local it = inv[s]; if it and it.name == name and it.count < 64 then return s end end
  return empty_slot()
end

local function agg(list)
  local m, out = {}, {}
  for _, it in pairs(list or {}) do
    if type(it) == "table" and it.name then m[it.name] = (m[it.name] or 0) + (it.count or 0) end
  end
  for k, v in pairs(m) do out[#out + 1] = { item = k, count = v } end
  table.sort(out, function(a, b) return a.count > b.count end)
  return out
end
local function inv_list() local l = {}; for s = 1, 16 do if inv[s] then l[#l + 1] = inv[s] end end; return l end

local function at_home() return st and st.pos.x == 0 and st.pos.y == 0 and st.pos.z == -1 end
local function chest_side() return SIDE_BY_REL[(2 - st.dir) % 4] end   -- сундук — в направлении -z

-- направление черепашки по тому, с какой стороны сундук (на стартовой клетке); nil — не ясно
local function dir_by_chest()
  local found
  for rel = 0, 3 do
    if peripheral.hasType(SIDE_BY_REL[rel], "inventory") then
      if found then return nil end
      found = rel
    end
  end
  if found == nil then return nil end
  return (2 - found) % 4
end

local function snapshot(side)
  local okl, list = pcall(peripheral.call, side, "list")
  local oks, size = pcall(peripheral.call, side, "size")
  if okl and type(list) == "table" then store.list = list end
  if oks and size then store.size = size end
end

-- Взять из сундука (он перед черепашкой) n штук item. Сундук отдаёт (suck) только первый непустой слот —
-- поэтому нужный предмет переносим в слот 1 (pushItems внутри того же сундука). -> сколько взято
local function pull(item, n)
  local got, tmp = 0, {}
  for _ = 1, 40 do
    if got >= n then break end
    local okl, list = pcall(peripheral.call, "front", "list")
    if not okl or type(list) ~= "table" then break end
    local src
    for slot, it in pairs(list) do
      if it.name == item and (not src or slot < src) then src = slot end
    end
    if not src then break end
    if src ~= 1 then
      if list[1] then
        local size = peripheral.call("front", "size") or 27
        local free
        for s = 2, size do if not list[s] then free = s; break end end
        if free then
          peripheral.call("front", "pushItems", "front", 1, 64, free)
        else
          -- сундук полон: временно забрать слот 1 к себе
          local e = empty_slot()
          if not e then break end
          turtle.select(e)
          if not turtle.suck(list[1].count) then break end
          scan()
          tmp[#tmp + 1] = e
        end
      end
      peripheral.call("front", "pushItems", "front", src, 64, 1)
      list = peripheral.call("front", "list")
      if not list[1] or list[1].name ~= item then break end
    end
    local slot = slot_for(item)
    if not slot then break end
    turtle.select(slot)
    local before = count_of(item)
    turtle.suck(math.min(n - got, list[1].count, 64))
    scan()
    local delta = count_of(item) - before
    if delta <= 0 then break end
    got = got + delta
  end
  for _, s in ipairs(tmp) do turtle.select(s); turtle.drop() end
  if #tmp > 0 then scan() end
  return got
end

-- Потребность до заполнения 15 слотов (1 — под выкопанное), начиная с текущей клетки: { item = n }
local function demand()
  local need, slots = {}, 0
  local y, i = st.layer, st.cell
  while y < plan.sy do
    local cells = layer_cells(y)
    while i <= #cells do
      local ch = cells[i].ch
      if ch ~= "-" then
        local item = plan.mats[ch]
        local had = need[item] or 0
        local add = math.ceil((had + 1) / 64) - math.ceil(had / 64)
        if slots + add > 15 then return need end
        slots = slots + add
        need[item] = had + 1
      end
      i = i + 1
    end
    y = y + 1
    i = 1
  end
  return need
end

-- Нехватка на весь остаток постройки (инвентарь + сундук): { {item, count} }
local function shortage()
  local need = {}
  local y, i = st.layer, st.cell
  while y < plan.sy do
    local cells = layer_cells(y)
    for k = i, #cells do
      local ch = cells[k].ch
      if ch ~= "-" then local item = plan.mats[ch]; need[item] = (need[item] or 0) + 1 end
    end
    y = y + 1
    i = 1
  end
  local have = {}
  for _, it in ipairs(inv_list()) do have[it.name] = (have[it.name] or 0) + it.count end
  for _, it in pairs(store.list) do have[it.name] = (have[it.name] or 0) + it.count end
  local out = {}
  for item, n in pairs(need) do
    if n > (have[item] or 0) then out[#out + 1] = { item = item, count = n - (have[item] or 0) } end
  end
  table.sort(out, function(a, b) return a.item < b.item end)
  return out
end

local FUEL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
  ["minecraft:blaze_rod"] = true, ["minecraft:dried_kelp_block"] = true, ["minecraft:lava_bucket"] = true }
local function is_fuel(name)
  if plan_items[name] then return false end       -- материал постройки не сжигаем
  if FUEL[name] then return true end
  return (name:find("coal") or name:find("coke")) ~= nil and not name:find("ore")
end

-- Сжечь топливо из слота s, пока уровень < target.
local function burn(s, target)
  turtle.select(s)
  if not turtle.refuel(0) then return false end
  while fuel_level() < target and turtle.getItemCount(s) > 0 do
    local before = fuel_level()
    if not turtle.refuel(1) then break end
    local per = fuel_level() - before
    if per <= 0 then break end
    local n = math.ceil((target - fuel_level()) / per)
    if n > 0 then turtle.refuel(math.min(n, turtle.getItemCount(s))) end
  end
  return true
end

-- Топливо из своего инвентаря (если игрок подложил прямо в черепашку). -> заправилась ли
local function refuel_inventory(target)
  local before = fuel_level()
  for s = 1, 16 do
    local it = inv[s]
    if it and is_fuel(it.name) and fuel_level() < target then burn(s, target) end
  end
  scan()
  return fuel_level() > before
end

local function fuel_target()
  local limit = turtle.getFuelLimit()
  if limit == "unlimited" then return 0 end
  local rest = 0
  for y = st.layer, plan.sy - 1 do rest = rest + #layer_cells(y) end
  return math.min(limit - 100, math.max(1000, rest * 3 + alt() * 8))
end

local function refuel_from_chest(target)
  for _ = 1, 8 do
    if fuel_level() >= target then return end
    local name
    for _, it in pairs(store.list) do if is_fuel(it.name) then name = it.name; break end end
    if not name then return end
    if pull(name, 64) == 0 then return end
    refuel_inventory(target)
    snapshot("front")
  end
end

-- выгрузить в сундук всё, что не нужно сейчас (выкопанное, остатки, пустые вёдра)
local function deposit(keep)
  scan()                                -- выкопанное по дороге в кэш инвентаря не попадало
  for s = 1, 16 do
    local it = inv[s]
    if it and not (keep and keep[it.name]) then
      turtle.select(s)
      turtle.drop()
    end
  end
  scan()
end

local function wait_retry(sec)
  local t = os.startTimer(sec or RETRY_EVERY)
  while true do
    local ev, a = os.pullEvent()
    if (ev == "timer" and a == t) or ev == "tmbuild_wake" then break end
  end
  pause_point()
end

-- Обслуживание у сундука: выгрузить лишнее, заправиться, взять материалы. item — без чего дальше нельзя,
-- need_fuel — сколько топлива нужно на следующую вылазку. Ждёт, пока недостающее не положат.
local function service(item, need_fuel)
  while true do
    pause_point()
    face(2)
    if not chest_ok() then
      report_blocked("nochest", "chest", 0, 0, -2)
      st.phase = "wait"; save()
      wait_retry()
    else
      snapshot("front")
      scan()
      local want = demand()
      deposit(want)
      local target = math.max(fuel_target(), need_fuel or 0)
      if fuel_level() < target then refuel_from_chest(target) end
      for it, n in pairs(want) do
        local have = count_of(it)
        if have < n then pull(it, n - have) end
      end
      deposit(want)                     -- остатки топлива и пустые вёдра — обратно
      snapshot("front")
      local short = shortage()
      local no_item = item ~= nil and count_of(item) == 0
      local no_fuel = fuel_level() < (need_fuel or 0)
      if no_item or no_fuel then
        st.phase = "wait"; save()
        send({ op = "need", job = st.job, missing = short, fuel = no_fuel, blocking = true })
        wait_retry()
      else
        if #short > 0 then send({ op = "need", job = st.job, missing = short, blocking = false }) end
        st.phase = "build"; save()
        last_block_sig = nil
        return
      end
    end
  end
end

-- ============================================================ команды владельца
pause_point = function()
  if ctl.stop then error(STOP, 0) end
  if ctl.pause then
    local was = st.phase
    st.phase, st.paused = "paused", true
    save()
    send({ op = "state", job = st.job, state = "paused" })
    while ctl.pause and not ctl.stop do os.pullEvent("tmbuild_wake") end
    if ctl.stop then error(STOP, 0) end
    st.phase = (was == "paused") and "build" or was
    st.paused = nil
    save()
    send({ op = "state", job = st.job, state = "resumed" })
  end
end

local function progress(force)
  local now = os.clock()
  if not force and now - last_progress < PROGRESS_EVERY then return end
  last_progress = now
  send({ op = "progress", job = st.job, layer = st.layer + 1, layers = plan.sy, cell = st.cell, done = done_count(),
    total = total_count(), pos = { st.pos.x, st.pos.y, st.pos.z }, skipped = st.skipped })
end

-- ============================================================ одна клетка
local function place_cell(item)
  local has, b = turtle.inspectDown()
  local cls
  if has and type(b) == "table" then
    if b.name == item or st.alias[item] == b.name then return "skip" end
    cls = classify(b)
    if cls == "natural" and st.clear_site then
      if not dig("d") then return "occupied", b.name end
    elseif cls ~= "soft" then
      return "occupied", b.name
    end
  end
  local s = find_slot(item)
  if not s then return "need" end
  turtle.select(s)
  local ok, err = turtle.placeDown()
  if not ok and cls == "soft" and not LIQUID[b.name] then
    dig("d")
    ok, err = turtle.placeDown()
  end
  if ok then
    inv[s].count = inv[s].count - 1
    if inv[s].count <= 0 then inv[s] = nil end
    if st.alias[item] == nil then
      -- какой блок получился из предмета (для проверки «уже стоит» после перезагрузки)
      local h2, nb = turtle.inspectDown()
      st.alias[item] = (h2 and type(nb) == "table") and nb.name or item
    end
    return "placed"
  end
  if tostring(err):find("No items") then scan(); return "need" end
  return "failed", tostring(err)
end

local function clear_cell()
  local has, b = turtle.inspectDown()
  if not has or type(b) ~= "table" or LIQUID[b.name] then return "skip" end
  local cls = classify(b)
  if cls == "soft" or (cls == "natural" and st.clear_site) then dig("d") end
  return "cleared"
end

local function blocked_wait(why, name, x, y, z)
  report_blocked(why == "natural" and "natural" or (why == "entity" and "entity" or "block"), name, x, y, z)
  st.phase = "blocked"; save()
  wait_retry()
  st.phase = "build"; save()
end

-- К сундуку (с ожиданием, если путь перекрыт или кончилось топливо).
local function go_home()
  while true do
    pause_point()
    local ok, why, name, x, y, z = travel(0, 0, -1)
    if ok then return true end
    if why == "fuel" then
      if not refuel_inventory(fuel_level() + cost_home(st.pos.x, st.pos.y, st.pos.z) + FUEL_MARGIN) then
        st.phase = "wait"; save()
        send({ op = "need", job = st.job, missing = {}, fuel = true, blocking = true, stranded = true })
        wait_retry()
      end
    else
      blocked_wait(why, name, x, y, z)
    end
  end
end

local function do_cell(c)
  local y = st.layer
  local item = c.ch ~= "-" and plan.mats[c.ch] or nil
  local fuel_fails = 0
  while true do
    pause_point()
    -- нет нужного блока: у сундука — сразу за ним; в поле — сначала к клетке (после перезагрузки блок мог
    -- уже стоять: ход «поставила — не успела записать»), place_cell скажет "need", если его там нет
    if item and not find_slot(item) and at_home() then
      service(item, cost_home(c.x, y + 1, c.z) * 2 + FUEL_MARGIN)
    elseif not fuel_ok(c.x, y + 1, c.z) then
      go_home()
      service(nil, cost_home(c.x, y + 1, c.z) * 2 + FUEL_MARGIN)
    else
      local ok, why, name, bx, by, bz = travel(c.x, y + 1, c.z)
      if ok then
        local r, extra
        if item then r, extra = place_cell(item) else r = clear_cell() end
        if r == "need" then
          go_home()
          service(item, cost_home(c.x, y + 1, c.z) * 2 + FUEL_MARGIN)
        else
          if r == "occupied" or r == "failed" then
            st.skipped = (st.skipped or 0) + 1
            report_blocked("skip", r == "occupied" and extra or ("failed: " .. tostring(extra)), c.x, y, c.z)
          end
          return
        end
      elseif why == "own" and bx == c.x and bz == c.z and by > y then
        return            -- над клеткой уже стоит блок плана: клетку построили раньше
      elseif why == "fuel" then
        fuel_fails = fuel_fails + 1
        go_home()
        service(nil, cost_home(c.x, y + 1, c.z) * 2 + FUEL_MARGIN)
        if fuel_fails >= 3 then                 -- оценка расходилась с фактом: не крутиться вхолостую
          send({ op = "need", job = st.job, missing = {}, fuel = true, blocking = true })
          wait_retry()
        end
      else
        blocked_wait(why, name, bx, by, bz)
      end
    end
  end
end

-- ============================================================ восстановление после перезагрузки
-- Неясность после перезагрузки (поворот мог не случиться; ход без расхода топлива) — это возможная ошибка всей
-- системы отсчёта: истинное положение = T(записанное), где T — жёсткое преобразование плоскости:
-- p' = R^k·p + t (R — поворот на 90° «вправо», как dir+1), dir' = dir + k. Все следующие ходы считаются в той же
-- (возможно сдвинутой) системе, поэтому T не меняется. Кандидаты T проверяются возвратом к сундуку без копания:
-- дошла и сундук там, где должен быть, — гипотеза верна. Сбой посреди проверки: новые кандидаты = старые ∘ новые.
local function rot(k, x, z)
  for _ = 1, k % 4 do x, z = z, -x end
  return x, z
end
local function T_apply(T, pos, dir)
  local x, z = rot(T.k, pos.x, pos.z)
  return { x = x + T.x, y = pos.y + T.y, z = z + T.z }, (dir + T.k) % 4
end
local function T_compose(A, B)          -- A∘B: сначала B, потом A
  local x, z = rot(A.k, B.x, B.z)
  return { k = (A.k + B.k) % 4, x = x + A.x, y = A.y + B.y, z = z + A.z }
end
local function T_inverse(A)
  local k = (4 - A.k) % 4
  local x, z = rot(k, A.x, A.z)
  return { k = k, x = -x, y = -A.y, z = -z }
end
local function T_is_id(A) return A.k % 4 == 0 and A.x == 0 and A.y == 0 and A.z == 0 end
-- поворот на k вокруг точки (px, pz)
local function T_turn_about(k, px, pz)
  local x, z = rot(k, px, pz)
  return { k = k % 4, x = px - x, y = 0, z = pz - z }
end

-- Добавить неясность Z (истина = T∘Z для каждого прежнего кандидата T).
local function add_doubt(Z)
  local pr = st.probe or { cands = {}, cur = 0 }
  -- система отсчёта сейчас «как есть»: если применён кандидат cur, пересчитать остальных относительно неё
  local base = {}
  local applied = pr.cur > 0 and pr.cands[pr.cur] or nil
  local inv = applied and T_inverse(applied) or { k = 0, x = 0, y = 0, z = 0 }
  base[1] = inv                                       -- исходная (нулевая) гипотеза
  for i, C in ipairs(pr.cands) do if i ~= pr.cur then base[#base + 1] = T_compose(C, inv) end end
  local out, seen = {}, {}
  local function add(T)
    local key = T.k .. "," .. T.x .. "," .. T.y .. "," .. T.z
    if not T_is_id(T) and not seen[key] and #out < 15 then seen[key] = true; out[#out + 1] = T end
  end
  add(Z)
  for _, Y in ipairs(base) do add(Y); add(T_compose(Y, Z)) end
  st.probe = { cands = out, cur = 0 }
end

-- Проверка гипотез: дойти до сундука без копания; не совпало — следующий кандидат.
local function probe_home()
  local pr = st.probe
  while true do
    NODIG = true
    local ok = travel(0, 0, -1)
    NODIG = false
    if ok and chest_ok() then st.probe = nil; save(); return end
    if pr.cur > 0 then st.pos, st.dir = T_apply(T_inverse(pr.cands[pr.cur]), st.pos, st.dir) end
    pr.cur = pr.cur + 1
    if pr.cur > #pr.cands then
      st.probe = nil
      st.phase = "lost"; save()
      send({ op = "state", job = st.job, state = "lost" })
      error(LOST, 0)
    end
    st.pos, st.dir = T_apply(pr.cands[pr.cur], st.pos, st.dir)
    save()
  end
end

local function recover()
  local p = st.pending
  if p then
    st.pending = nil
    if p.kind == "move" then
      local f = turtle.getFuelLevel()
      if type(f) == "number" and type(p.fuel) == "number" then
        if f < p.fuel then apply_move(p.d, p.dir) end          -- топливо ушло — ход состоялся
      else
        -- топливо не расходуется: считаем, что ход был; если нет — истина сдвинута назад на этот ход
        apply_move(p.d, p.dir)
        local dx, dy, dz = 0, 0, 0
        if p.d == "u" then dy = 1 elseif p.d == "d" then dy = -1 else dx, dz = DX[p.dir], DZ[p.dir] end
        add_doubt({ k = 0, x = -dx, y = -dy, z = -dz })
      end
    elseif p.kind == "turn" then
      st.dir = p.to                                            -- считаем, что повернулась
      local d = (not st.probe and at_home()) and dir_by_chest() or nil
      if d then st.dir = d
      else add_doubt(T_turn_about((p.from - p.to) % 4, st.pos.x, st.pos.z)) end
    end
    save()
  end
  if st.probe then probe_home() end
end

-- Игрок поставил потерявшуюся черепашку на старт лицом к стройке и сказал «продолжить».
local function recalibrate()
  if peripheral.hasType("back", "inventory") then
    st.pos, st.dir, st.pending, st.probe = { x = 0, y = 0, z = -1 }, 0, nil, nil
    st.phase = "build"
    save()
    return true
  end
  send({ op = "state", job = st.job, state = "lost" })
  return false
end

-- ============================================================ стройка целиком
local function finish()
  go_home()
  face(2)
  if chest_ok() then deposit(nil) end
  face(0)
  st.phase = "done"
  save()
  progress(true)
  send({ op = "state", job = st.job, state = "done", skipped = st.skipped })
  say("tmbuild: «" .. tostring(plan.name) .. "» готово")
end

local function run_job()
  recover()
  if st.phase == "done" then return end
  st.phase = "build"
  save()
  scan()
  progress(true)
  while st.layer < plan.sy do
    local cells = layer_cells(st.layer)
    while st.cell <= #cells do
      pause_point()
      do_cell(cells[st.cell])
      st.cell = st.cell + 1
      save()
      progress(false)
    end
    st.layer = st.layer + 1
    st.cell = 1
    save()
    progress(true)
  end
  finish()
end

local function clear_job()
  for _, p in ipairs({ STATE, STATE .. ".tmp", PLAN, PLAN .. ".tmp" }) do if fs.exists(p) then fs.delete(p) end end
  st, plan, plan_items, rows, cells_cache = nil, nil, {}, {}, {}
end

-- «Стоп»: к сундуку, выгрузить всё, забыть задание.
local function do_stop()
  ctl.stop, ctl.pause, ctl.resume, NODIG = false, false, false, false
  local job, note = st.job, nil
  if st.phase ~= "lost" then
    local ok = travel(0, 0, -1)
    if ok then
      face(2)
      if chest_ok() then deposit(nil) end
      face(0)
    else
      note = "не дошла до сундука"
    end
  else
    note = "черепашка не на старте"
  end
  clear_job()
  send({ op = "state", job = job, state = "stopped", error = note })
end

-- Одна итерация работы (для главного цикла и тестов). "Terminated" (Ctrl+T, выгрузка) — пробрасывается.
local function work()
  local ok, err = pcall(run_job)
  if ok then return "done" end
  if err == STOP then
    local ok2, e2 = pcall(do_stop)
    if not ok2 and e2 == "Terminated" then error(e2, 0) end
    return "stopped"
  elseif err == LOST then return "lost"
  elseif err == "Terminated" then error(err, 0)
  end
  st.phase, st.error = "error", tostring(err)
  save()
  send({ op = "state", job = st.job, state = "error", error = tostring(err) })
  warn("tmbuild: ошибка: " .. tostring(err))
  return "error"
end

-- ============================================================ связь
local function has_tool()
  for _, f in ipairs({ turtle.getEquippedLeft, turtle.getEquippedRight }) do
    if f then
      local ok, d = pcall(f)
      if ok and type(d) == "table" and type(d.name) == "string"
        and (d.name:find("pickaxe") or d.name:find("shovel") or d.name:find("axe")) then return true end
    end
  end
  if turtle.getEquippedLeft then return false end
  return nil
end

local function hello_msg()
  if not st then snapshot("back"); scan() end   -- без стройки черепашка стоит на старте: сундук позади
  local m = { op = "hello", from = "tmbuild", owner = owner, label = label, version = VERSION,
    fuel = turtle.getFuelLevel(), fuel_limit = turtle.getFuelLimit(), tool = has_tool(),
    state = (st and st.job) and st.phase or "idle", job = st and st.job or nil, name = plan and plan.name or nil,
    store = agg(store.list), store_size = store.size, inv = agg(inv_list()), at_home = (not st) or at_home() }
  if st and plan then
    m.layer, m.layers, m.cell, m.done, m.total = st.layer + 1, plan.sy, st.cell, done_count(), total_count()
  end
  return m
end

local function send_inv()
  if not st then snapshot("back"); scan()
  elseif at_home() then snapshot(chest_side()) end
  send({ op = "inv", store = agg(store.list), store_size = store.size, inv = agg(inv_list()),
    fuel = turtle.getFuelLevel() })
end

local function accept(m)
  local function reject(why) send({ op = "rejected", job = m.job, error = why }) end
  if st and st.job and st.phase ~= "done" then return reject("занята стройкой «" .. tostring(plan and plan.name) .. "»") end
  local sx, sy, sz, ox = tonumber(m.sx), tonumber(m.sy), tonumber(m.sz), tonumber(m.ox)
  if type(m.job) ~= "string" or type(m.layers) ~= "table" or type(m.mats) ~= "table" or not sx or not sy or not sz
    or not ox or #m.layers ~= sy then return reject("неверное задание") end
  if not peripheral.hasType("back", "inventory") then
    return reject("позади черепашки нет сундука-склада (поставьте сундук за ней или её перед сундуком)")
  end
  plan = { job = m.job, name = tostring(m.name or "?"), ox = ox, sx = sx, sy = sy, sz = sz, layers = m.layers, mats = m.mats }
  write_atomic(PLAN, json.encode(plan))
  rows, cells_cache, plan_items = {}, {}, {}
  for _, item in pairs(plan.mats) do plan_items[item] = true end
  local from = math.max(0, math.min(sy - 1, math.floor((tonumber(m.from_layer) or 1) - 1)))
  st = { job = m.job, player = m.player, clear_site = m.clear_site == true, pos = { x = 0, y = 0, z = -1 }, dir = 0,
    layer = from, start_layer = from, cell = 1, phase = "build", alias = {}, skipped = 0 }
  save()
  last_progress, last_block_sig = -1000, nil
  ctl.stop, ctl.pause, ctl.resume = false, false, false
  send({ op = "accepted", job = m.job })
  say("tmbuild: «" .. plan.name .. "» от " .. tostring(m.player))
  wake()
end

local function handle(sender, m)
  if type(m) ~= "table" or m.from ~= "tmai" then return end
  if not owner then owner = sender; settings.set("tmbuild.owner", sender); settings.save() end
  if sender ~= owner then return end
  local op = m.op
  if op == "job" then accept(m)
  elseif op == "pause" then ctl.pause = true; wake()
  elseif op == "resume" then ctl.pause = false; ctl.resume = true; wake()
  elseif op == "stop" then ctl.stop = true; wake()
  elseif op == "recheck" then wake()
  elseif op == "inv" then send_inv()
  elseif op == "ping" then rednet.send(owner, hello_msg(), PROTO)
  end
end

local function load_all()
  st = load_json(STATE)
  if st and not st.job then st = nil end
  plan = st and load_json(PLAN) or nil
  if st and (not plan or plan.job ~= st.job) then st, plan = nil, nil end
  rows, cells_cache, plan_items = {}, {}, {}
  if plan then for _, item in pairs(plan.mats) do plan_items[item] = true end end
  if st then
    st.alias = st.alias or {}
    ctl.pause = st.paused == true
  end
end

if LIB then
  return {
    load = load_all, handle = handle, work = work, run_job = run_job, recalibrate = recalibrate, hello = hello_msg,
    classify = classify, layer_cells = layer_cells,
    state = function() return st end, plan = function() return plan end, ctl = ctl,
    set_owner = function(id) owner = id end,
  }
end

-- ============================================================ главный цикл
local function builder()
  while true do
    if st and st.job and st.phase ~= "done" and st.phase ~= "error" and st.phase ~= "lost" then
      work()
    elseif st and st.job and (st.phase == "error" or st.phase == "lost") then
      ctl.resume = false
      repeat os.pullEvent("tmbuild_wake") until ctl.stop or ctl.resume
      if ctl.stop then
        local ok, e = pcall(do_stop)
        if not ok and e == "Terminated" then error(e, 0) end
      else
        ctl.resume = false
        if st.phase == "lost" then recalibrate() else st.phase = "build"; save() end
      end
    else
      os.pullEvent("tmbuild_wake")
      if not (st and st.job) then ctl.stop, ctl.pause = false, false end
    end
  end
end

local function comms()
  local t = os.startTimer(1)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == t then
      rednet.broadcast(hello_msg(), PROTO)
      t = os.startTimer(HELLO_EVERY)
    elseif ev == "rednet_message" and c == PROTO then
      handle(a, b)
    end
  end
end

local modem = false
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.hasType(n, "modem") then rednet.open(n); modem = true end
end
if not modem then warn("tmbuild: нет модема — поставьте беспроводной или проводной модем"); return end
load_all()
if st then say("tmbuild: продолжаю «" .. tostring(plan.name) .. "», слой " .. (st.layer + 1) .. "/" .. plan.sy) end
say("tmbuild: черепашка-строитель #" .. os.getComputerID() .. " ждёт заданий ЛОЦМАНа" ..
  (owner and (" (компьютер #" .. owner .. ")") or "") .. ". Сундук-склад — позади неё.")
_G.__tmbuild_running = true
local ok, err = pcall(parallel.waitForAny, builder, comms)
_G.__tmbuild_running = nil
if not ok and err ~= "Terminated" then warn("tmbuild: " .. tostring(err)) end
