-- tmai.apps.wp — «Метки»: общие точки экипажа (дом, шахта, портал, точки смерти, прочее) с координатами.
-- Учётных записей нет: автор — ник (у терминала — ctx.speaker(), с КПК — ник КПК, у нейросети — кто спросил).
--
-- Вкладка терминала (список по измерениям):
--   «+ метка здесь» — там, где стоит игрок у терминала (позиция через TM-NAV, операция pos);
--   «+ по координатам» — строка «X Y Z [измерение] [имя]», напр. «120 64 -40 незер Портал»;
--   Enter — подробно (переименовать, сменить вид; Delete — удалить), Delete — удалить (строка «Вернуть» внизу).
--   Расстояние и сторона света — от игрока у терминала (позиция обновляется в tick).
-- Точки смерти: раз в 20 с операция TM-NAV wp_deaths (поле LastDeathLocation онлайн-игроков, tmnav/wp.lua);
--   новая смерть — метка «Смерть <ник>» (последние 3 на игрока) и сообщение на КПК этого игрока.
-- КПК (radio): list, add_here, add, remove, rename — расстояние и направление от игрока с КПК.
-- Инструменты нейросети: wp_list, wp_add, wp_remove, wp_route.
-- Данные: ctx.data.list = { {id, name, x, y, z, dim, kind, author, t}, … }, next_id, deaths_seen[ник] = "dim x y z".

local json = require("tmai.json")
local text = require("tmai.text")
local util = require("tmai.util")

local M = { id = "wp", title = "Метки", short = "Метки", order = 60, monitor = false, every = 20 }

local MAX_WP, MAX_DEATHS, NAME_MAX = 200, 3, 32
local LIMIT_XZ, Y_MIN, Y_MAX = 30000000, -2048, 4096
local OVER, NETHER, END = "minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"

local KINDS = { "home", "mine", "portal", "death", "other" }
local KIND_RU = { home = "дом", mine = "шахта", portal = "портал", death = "смерть", other = "прочее" }
local KIND_FG = { home = colors.lime, mine = colors.orange, portal = colors.magenta, death = colors.red, other = colors.white }
local DIM_RU = { [OVER] = "Верхний мир", [NETHER] = "Незер", [END] = "Энд" }
local DIRS = { "восток", "юго-восток", "юг", "юго-запад", "запад", "северо-запад", "север", "северо-восток" }
local DIRS_S = { "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ", "С", "СВ" }
local atan2 = math.atan2 or math.atan

-- ---------- строки (без %s/%w на UTF-8: в Cobalt классы на байтах >= 0x80 ненадёжны) ----------
local function trim(s)
  s = tostring(s == nil and "" or s):gsub("[%z\1-\31]", " "):gsub("  +", " ")
  return (s:gsub("^ +", ""):gsub(" +$", ""))
end

-- Нижний регистр латиницы и кириллицы (UTF-8), ё = е — для поиска по имени.
local function norm(s)
  s = trim(s):gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)
  s = s:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)   -- А..П
  s = s:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)   -- Р..Я
  s = s:gsub("\208\129", "\208\181"):gsub("\209\145", "\208\181")                                -- Ё ё -> е
  return s
end

local function valid_player(n) return type(n) == "string" and #n >= 3 and #n <= 16 and n:match("^[A-Za-z0-9_]+$") ~= nil end

local function clean_name(s)
  s = trim(s)
  if text.len(s) > NAME_MAX then s = trim(text.sub(s, 1, NAME_MAX)) end
  return s
end

local DIM_ALIAS = {
  overworld = OVER, ["верхний"] = OVER, ["верх"] = OVER, ["мир"] = OVER, ["обычный"] = OVER, ["земля"] = OVER,
  nether = NETHER, the_nether = NETHER, ["незер"] = NETHER, ["нижний"] = NETHER, ["ад"] = NETHER,
  ["end"] = END, the_end = END, ["энд"] = END, ["край"] = END,
}
local function parse_dim(s)
  s = norm(s)
  if s == "" then return nil end
  if DIM_ALIAS[s] then return DIM_ALIAS[s] end
  if s:match("^[a-z0-9_%.%-]+:[a-z0-9_/%.%-]+$") then return s end
  return nil
end
local function dim_name(d)
  d = tostring(d or OVER)
  return DIM_RU[d] or (d:match(":(.+)$") or d)
end

local KIND_ALIAS = { home = "home", base = "home", ["дом"] = "home", ["база"] = "home", mine = "mine", ["шахта"] = "mine",
  portal = "portal", ["портал"] = "portal", death = "death", ["смерть"] = "death", other = "other", ["прочее"] = "other",
  ["другое"] = "other" }
local function parse_kind(s)
  if s == nil then return nil end
  return KIND_ALIAS[norm(s)]
end
-- Вид по имени: «Дом у озера» — дом, «Шахта алмазов» — шахта, «Портал» — портал.
local function guess_kind(name)
  local n = norm(name)
  if n:find("дом", 1, true) or n:find("баз", 1, true) or n:find("home", 1, true) or n:find("base", 1, true) then return "home" end
  if n:find("шахт", 1, true) or n:find("руд", 1, true) or n:find("mine", 1, true) then return "mine" end
  if n:find("портал", 1, true) or n:find("portal", 1, true) then return "portal" end
  return "other"
end

local function int(v, lo, hi)
  v = tonumber(v)
  if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
  v = math.floor(v)
  if v < lo or v > hi then return nil end
  return v
end

-- «X Y Z [измерение] [имя]» -> { x, y, z, dim, name } или nil, ошибка
local function parse_coords(s, default_dim)
  s = trim(s)
  local toks, pos = {}, 1
  while #toks < 4 do
    local a, b, tk = s:find("^[ ,;]*([^ ,;]+)", pos)
    if not a then break end
    toks[#toks + 1] = { tk = tk, rest = b + 1 }
    pos = b + 1
  end
  if #toks < 3 then return nil, "нужно три числа: X Y Z (например: 120 64 -40)" end
  local x, y, z = int(toks[1].tk, -LIMIT_XZ, LIMIT_XZ), int(toks[2].tk, Y_MIN, Y_MAX), int(toks[3].tk, -LIMIT_XZ, LIMIT_XZ)
  if not (x and y and z) then return nil, "координаты — целые числа: X Y Z (Y от -2048 до 4096)" end
  local dim, rest = default_dim or OVER, toks[3].rest
  if toks[4] then
    local d = parse_dim(toks[4].tk)
    if d then dim, rest = d, toks[4].rest end
  end
  return { x = x, y = y, z = z, dim = dim, name = clean_name(s:sub(rest):gsub("^[ ,;]+", "")) }
end

-- ---------- геометрия ----------
local function fmt_dist(n)
  if n >= 10000 then return ("%d тыс."):format(math.floor(n / 1000 + 0.5)) end
  return tostring(math.floor(n))
end

-- Откуда (from) и куда (to) в одном измерении -> { dist, dir, dir_s, dy, text }
local function geo(from, to)
  local dx, dz, dy = to.x - from.x, to.z - from.z, to.y - from.y
  local dist = math.floor(math.sqrt(dx * dx + dz * dz) + 0.5)
  local r = { same = true, dist = dist, dy = math.floor(dy) }
  if dist < 3 then
    r.text = "вы на месте"
  else
    local ang = math.deg(atan2(dz, dx))       -- +x — восток, +z — юг
    local i = (math.floor((ang + 22.5) / 45) % 8) + 1
    r.dir, r.dir_s = DIRS[i], DIRS_S[i]
    r.text = fmt_dist(dist) .. " бл. на " .. r.dir
  end
  if dy >= 3 then r.text = r.text .. ", выше на " .. math.floor(dy)
  elseif dy <= -3 then r.text = r.text .. ", ниже на " .. math.floor(-dy) end
  return r
end

-- Маршрут от позиции игрока до метки; в разных измерениях — подсказка через Незер (1 блок Незера = 8 блоков мира).
local function route(from, w)
  if not from then return nil end
  if from.dim == w.dim then return geo(from, w) end
  local r = { same = false, text = "метка в другом измерении: " .. dim_name(w.dim) }
  if from.dim == NETHER and w.dim == OVER then
    local tx, tz = math.floor(w.x / 8), math.floor(w.z / 8)
    local g = geo(from, { x = tx, y = from.y, z = tz })
    r.nether = { x = tx, z = tz }
    r.text = ("метка в Верхнем мире; в Незере ей соответствует X %d Z %d — %s, там портал наверх"):format(tx, tz, g.text)
  elseif from.dim == OVER and w.dim == NETHER then
    r.text = ("метка в Незере; в Верхнем мире это около X %d Z %d — портал там приведёт к ней"):format(w.x * 8, w.z * 8)
  end
  return r
end

local function ago(t)
  local s = util.now() - (tonumber(t) or 0)
  if s < 90 then return "только что" end
  if s < 3600 then return math.floor(s / 60 + 0.5) .. " мин назад" end
  if s < 86400 * 2 then return math.floor(s / 3600 + 0.5) .. " ч назад" end
  return math.floor(s / 86400 + 0.5) .. " дн. назад"
end

local function coords(w) return ("%d %d %d"):format(w.x, w.y, w.z) end

-- ---------- данные ----------
local V = { open = nil, msg = nil, pos = {} }   -- экран терминала и кэш позиций игроков (не сохраняются)

local function note(s, fg) V.msg = { text = s, fg = fg or colors.yellow, till = os.clock() + 30 } end

local function list(ctx) return ctx.data.list end

local function by_id(ctx, id)
  id = tonumber(id)
  for i, w in ipairs(list(ctx)) do if w.id == id then return w, i end end
end

-- Метка по номеру или имени (точное совпадение, иначе часть имени; из нескольких — самая новая).
local function find(ctx, ref)
  local w = by_id(ctx, ref)
  if w then return w end
  if type(ref) ~= "string" or trim(ref) == "" then return nil end
  local q, best = norm(ref), nil
  for _, it in ipairs(list(ctx)) do
    if norm(it.name) == q and (not best or (it.t or 0) > (best.t or 0)) then best = it end
  end
  if best then return best end
  for _, it in ipairs(list(ctx)) do
    if norm(it.name):find(q, 1, true) and (not best or (it.t or 0) > (best.t or 0)) then best = it end
  end
  return best
end

-- Добавить метку: p = { name, x, y, z, dim, kind, author } (уже проверенные) -> метка | nil, ошибка
local function add(ctx, p)
  local d = ctx.data
  if #d.list >= MAX_WP then return nil, "меток уже " .. MAX_WP .. " — удалите ненужные" end
  d.next_id = (tonumber(d.next_id) or 0) + 1
  local name = clean_name(p.name)
  if name == "" then name = "Метка " .. d.next_id end
  local w = { id = d.next_id, name = name, x = p.x, y = p.y, z = p.z, dim = p.dim or OVER,
    kind = KIND_RU[p.kind or ""] and p.kind or guess_kind(name), author = p.author or "?", t = util.now() }
  d.list[#d.list + 1] = w
  ctx.save()
  return w
end

local function remove(ctx, id)
  local w, i = by_id(ctx, id)
  if not w then return nil end
  table.remove(ctx.data.list, i)
  ctx.data.trash = { w = w, t = util.now() }
  ctx.save()
  return w
end

-- Позиция игрока через TM-NAV (кэш 5 с). wait=false — только кэш (для рисования).
local function pos_of(ctx, player, wait)
  if not valid_player(player) then return nil, "нет ника" end
  local c = V.pos[player]
  if c and (not wait or os.clock() - c.t < 5) then return c.p end
  if not wait then return nil end
  local p, err = ctx.nav("pos", { player = player })
  if type(p) ~= "table" or not tonumber(p.x) then return nil, err or "игрок не найден" end
  p = { x = math.floor(tonumber(p.x)), y = math.floor(tonumber(p.y) or 64), z = math.floor(tonumber(p.z)),
    dim = type(p.dim) == "string" and p.dim or OVER }
  V.pos[player] = { p = p, t = os.clock() }
  return p
end

local function why_no_pos(player, err)
  return "не узнать, где " .. player .. ": " .. tostring(err or "нет связи с навигационным модулем")
end

-- Метка там, где стоит игрок.
local function add_here(ctx, player, name, kind)
  if not valid_player(player) then
    return nil, "не знаю, кто вы: подойдите к детектору игроков у терминала или выберите имя в «Чате» (щелчок по имени)"
  end
  local p, err = pos_of(ctx, player, true)
  if not p then return nil, why_no_pos(player, err) end
  return add(ctx, { name = name, x = p.x, y = p.y, z = p.z, dim = p.dim, kind = kind, author = player })
end

-- Точки смерти онлайн-игроков (TM-NAV wp_deaths). Новая — метка «Смерть <ник>», у игрока остаются последние 3.
local function check_deaths(ctx)
  local r = ctx.nav("wp_deaths", {})
  if type(r) ~= "table" or type(r.deaths) ~= "table" then return 0 end
  local d = ctx.data
  d.deaths_seen = d.deaths_seen or {}
  local added = 0
  for _, e in ipairs(r.deaths) do
    local x, y, z = int(e.x, -LIMIT_XZ, LIMIT_XZ), int(e.y, Y_MIN, Y_MAX), int(e.z, -LIMIT_XZ, LIMIT_XZ)
    local dim = type(e.dim) == "string" and e.dim:match("^[a-z0-9_%.%-]+:[a-z0-9_/%.%-]+$") and e.dim
    if valid_player(e.player) and x and y and z and dim then
      local key = e.player:lower()
      local sig = ("%s %d %d %d"):format(dim, x, y, z)
      if d.deaths_seen[key] ~= sig then
        d.deaths_seen[key] = sig
        -- у игрока — только последние MAX_DEATHS точек смерти: старые убираем до добавления новой
        local mine = {}
        for _, it in ipairs(d.list) do
          if it.kind == "death" and tostring(it.author):lower() == key then mine[#mine + 1] = it end
        end
        table.sort(mine, function(a, b) return (a.t or 0) == (b.t or 0) and a.id > b.id or (a.t or 0) > (b.t or 0) end)
        for i = MAX_DEATHS, #mine do
          for j, it in ipairs(d.list) do if it == mine[i] then table.remove(d.list, j); break end end
        end
        local w = add(ctx, { name = "Смерть " .. e.player, x = x, y = y, z = z, dim = dim, kind = "death", author = e.player })
        if w then
          added = added + 1
          ctx.kpk({ op = "notify", level = "info", from = "Метки",
            text = ("Точка смерти сохранена: %s (%s). Метка «%s» — во вкладке «Метки»."):format(coords(w), dim_name(dim), w.name) },
            e.player)
        end
        ctx.save()
      end
    end
  end
  return added
end

-- Метка для ответа (КПК, нейросеть): поля + маршрут от позиции from.
local function view(w, from)
  local r = { id = w.id, name = w.name, x = w.x, y = w.y, z = w.z, dim = w.dim, dim_name = dim_name(w.dim),
    kind = w.kind, kind_ru = KIND_RU[w.kind] or "прочее", author = w.author, ago = ago(w.t) }
  local rt = route(from, w)
  if rt then
    r.same_dim = rt.same
    r.dist, r.dir, r.dir_s, r.dy = rt.dist, rt.dir, rt.dir_s, rt.dy
    r.route = rt.text
    r.nether = rt.nether
  end
  return r
end

-- Отсортированный список для ответа: в одном измерении с игроком — по расстоянию, остальные — по имени.
local function sorted_views(ctx, from, filter, limit)
  local out = {}
  for _, w in ipairs(list(ctx)) do
    if not filter or filter(w) then out[#out + 1] = view(w, from) end
  end
  table.sort(out, function(a, b)
    if (a.dist ~= nil) ~= (b.dist ~= nil) then return a.dist ~= nil end
    if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
    if a.dim ~= b.dim then return a.dim < b.dim end
    return norm(a.name) < norm(b.name)
  end)
  local total = #out
  while limit and #out > limit do table.remove(out) end
  return out, total
end

-- ---------- приложение ----------
function M.init(ctx)
  local d = ctx.data
  if type(d.list) ~= "table" then d.list = {} end
  if type(d.deaths_seen) ~= "table" then d.deaths_seen = {} end
  d.next_id = tonumber(d.next_id) or 0
  for _, w in ipairs(d.list) do if (tonumber(w.id) or 0) > d.next_id then d.next_id = w.id end end
end

function M.tick(ctx)
  check_deaths(ctx)
  local sp = ctx.speaker()
  if sp then pos_of(ctx, sp, true) end
end

function M.status(ctx)
  local n = #list(ctx)
  return n > 0 and ("меток: " .. n) or "меток нет"
end

local GROUPS = { OVER, NETHER, END }

local function item_row(w, from, sp)
  local rt = route(from, w)
  local desc = (KIND_RU[w.kind] or "прочее") .. " · " .. tostring(w.author) .. " · " .. ago(w.t)
  if rt then desc = "От " .. sp .. ": " .. rt.text .. " · " .. desc end
  return { text = w.name, value = coords(w), fg = KIND_FG[w.kind] or colors.white, desc = desc,
    action = { op = "open", id = w.id, label = "подробно" }, del = { op = "remove", id = w.id, label = "удалить" } }
end

local function detail_rows(ctx, w, out, sp, width)
  local from = sp and pos_of(ctx, sp, false)
  local del = { op = "remove", id = w.id, label = "удалить метку" }
  local about = ("Метка №%d · %s · %s"):format(w.id, coords(w), dim_name(w.dim))
  out[#out + 1] = { text = "< к списку", action = { op = "close", label = "к списку" }, del = del, desc = about }
  out[#out + 1] = { text = w.name, header = true }
  out[#out + 1] = { text = "Координаты", value = ("X %d  Y %d  Z %d"):format(w.x, w.y, w.z) }
  out[#out + 1] = { text = "Измерение", value = dim_name(w.dim) }
  out[#out + 1] = { text = "Вид", value = KIND_RU[w.kind] or "прочее", fg = KIND_FG[w.kind],
    action = { op = "kind", id = w.id, label = "сменить вид" }, del = del,
    desc = "Виды по кругу: дом, шахта, портал, смерть, прочее" }
  out[#out + 1] = { text = "Поставил", value = tostring(w.author) }
  out[#out + 1] = { text = "Когда", value = ago(w.t) }
  local rt = route(from, w)
  if rt then
    for _, l in ipairs(text.wrap("От " .. sp .. ": " .. rt.text, math.max(10, (width or 51) - 4))) do
      out[#out + 1] = { text = l, fg = colors.yellow }
    end
  elseif sp then
    out[#out + 1] = { text = "Где " .. sp .. " — пока неизвестно (нужен навигационный модуль)", fg = colors.gray }
  end
  out[#out + 1] = { text = "Переименовать", del = del, desc = about,
    prompt = { label = "Новое имя", op = "rename", id = w.id, value = w.name, max = NAME_MAX } }
  return out
end

function M.rows(ctx, w)
  local out = {}
  local sp = ctx.speaker()
  -- строка 1 — всегда сообщение или справка (чтобы строки ниже не сдвигались)
  if V.msg and os.clock() < V.msg.till then
    out[1] = { text = V.msg.text, fg = V.msg.fg }
  else
    V.msg = nil
    local from = sp and pos_of(ctx, sp, false)
    out[1] = { text = sp and from and ("%s: %s, %s"):format(sp, coords(from), dim_name(from.dim))
      or (sp and (sp .. ": позиция неизвестна") or "Кто у терминала — неизвестно"), fg = colors.lightGray }
  end
  if V.open then
    local it = by_id(ctx, V.open)
    if it then return detail_rows(ctx, it, out, sp, w) end
    V.open = nil
  end
  out[#out + 1] = { text = "+ метка здесь", fg = colors.lime,
    desc = sp and ("Метка там, где стоит " .. sp .. " (Enter, имя — пусто: «Метка N»)") or "Нужен игрок у терминала (детектор или выбор имени в «Чате»)",
    prompt = { label = "Имя метки", op = "add_here", max = NAME_MAX, placeholder = "пусто — «Метка N»" } }
  out[#out + 1] = { text = "+ по координатам", fg = colors.lime, desc = "Например: 120 64 -40 незер Портал (измерение и имя — по желанию)",
    prompt = { label = "X Y Z [изм.] [имя]", op = "add_xyz", max = 80 } }
  local from = sp and pos_of(ctx, sp, false)
  local groups, others, deaths = {}, {}, {}
  for _, it in ipairs(list(ctx)) do
    if it.kind == "death" then deaths[#deaths + 1] = it
    else
      if not groups[it.dim] then
        groups[it.dim] = {}
        if not DIM_RU[it.dim] then others[#others + 1] = it.dim end
      end
      table.insert(groups[it.dim], it)
    end
  end
  table.sort(others)
  local order = {}
  for _, g in ipairs(GROUPS) do order[#order + 1] = g end
  for _, g in ipairs(others) do order[#order + 1] = g end
  local function by_dist(a, b)
    local ra, rb = route(from, a), route(from, b)
    local da, db = ra and ra.dist, rb and rb.dist
    if da and db and da ~= db then return da < db end
    if (da ~= nil) ~= (db ~= nil) then return da ~= nil end
    return a.id < b.id
  end
  for _, g in ipairs(order) do
    local items = groups[g]
    if items and #items > 0 then
      table.sort(items, by_dist)
      out[#out + 1] = { text = dim_name(g), header = true }
      for _, it in ipairs(items) do out[#out + 1] = item_row(it, from, sp) end
    end
  end
  if #deaths > 0 then
    table.sort(deaths, function(a, b) return (a.t or 0) > (b.t or 0) end)
    out[#out + 1] = { text = "Точки смерти", header = true }
    for _, it in ipairs(deaths) do out[#out + 1] = item_row(it, from, sp) end
  end
  if #list(ctx) == 0 then
    out[#out + 1] = { text = "Меток пока нет. Встаньте у терминала и выберите «+ метка здесь».", fg = colors.gray }
  end
  local tr = ctx.data.trash
  if tr and tr.w and util.now() - (tr.t or 0) < 600 and not by_id(ctx, tr.w.id) then
    out[#out + 1] = { text = "Вернуть «" .. tostring(tr.w.name) .. "»", fg = colors.yellow,
      action = { op = "undo", label = "вернуть удалённую" }, desc = "Отменить удаление метки" }
  end
  return out
end

function M.action(ctx, act)
  local op = act.op
  if op == "open" then
    V.open = tonumber(act.id)
    if act.player then pos_of(ctx, act.player, true) end
  elseif op == "close" then
    V.open = nil
  elseif op == "add_here" then
    local w, err = add_here(ctx, act.player, act.value)
    if w then note("Метка «" .. w.name .. "»: " .. coords(w) .. ", " .. dim_name(w.dim), colors.lime)
    else note(err, colors.orange) end
  elseif op == "add_xyz" then
    local from = act.player and pos_of(ctx, act.player, false)
    local p, err = parse_coords(act.value, from and from.dim or OVER)
    if not p then note(err, colors.orange); return end
    p.author = act.player or "терминал"
    local w, e2 = add(ctx, p)
    if w then note("Метка «" .. w.name .. "»: " .. coords(w) .. ", " .. dim_name(w.dim), colors.lime)
    else note(e2, colors.orange) end
  elseif op == "rename" then
    local w = by_id(ctx, act.id)
    local name = clean_name(act.value)
    if w and name ~= "" then w.name = name; ctx.save(); note("Переименовано: «" .. name .. "»", colors.lime)
    elseif w then note("Имя не может быть пустым", colors.orange) end
  elseif op == "kind" then
    local w = by_id(ctx, act.id)
    if w then
      local i = 1
      for k, v in ipairs(KINDS) do if v == w.kind then i = k end end
      w.kind = KINDS[i % #KINDS + 1]
      ctx.save()
    end
  elseif op == "remove" then
    local w = remove(ctx, act.id)
    V.open = nil
    if w then note("Удалена «" .. w.name .. "» — строка «Вернуть» внизу списка отменит", colors.yellow) end
  elseif op == "undo" then
    local tr = ctx.data.trash
    if tr and tr.w and not by_id(ctx, tr.w.id) then
      table.insert(ctx.data.list, tr.w)
      ctx.data.trash = nil
      ctx.save()
      note("Метка «" .. tr.w.name .. "» возвращена", colors.lime)
    end
  end
end

-- ---------- КПК ----------
local function radio_item(ctx, msg, player)
  local w = by_id(ctx, msg.id)
  if not w then return nil, "нет такой метки" end
  return w
end

M.radio = {
  list = function(ctx, msg, sender, player)
    local from, err
    if player then from, err = pos_of(ctx, player, true) end
    local items, total = sorted_views(ctx, from, nil, 80)
    local r = { items = items, total = total }
    if from then r.pos = { x = from.x, y = from.y, z = from.z, dim = from.dim, dim_name = dim_name(from.dim) }
    else r.pos_err = player and why_no_pos(player, err) or "у КПК не задан ник" end
    return r
  end,
  add_here = function(ctx, msg, sender, player)
    if not player then return nil, "у КПК не задан ник (set tmpda.player <ник>)" end
    local w, err = add_here(ctx, player, type(msg.name) == "string" and msg.name or "", parse_kind(msg.kind))
    if not w then return nil, err end
    return view(w, pos_of(ctx, player, false))
  end,
  add = function(ctx, msg, sender, player)
    local x, y, z = int(msg.x, -LIMIT_XZ, LIMIT_XZ), int(msg.y, Y_MIN, Y_MAX), int(msg.z, -LIMIT_XZ, LIMIT_XZ)
    if not (x and y and z) then return nil, "неверные координаты" end
    local dim = OVER
    if msg.dim ~= nil and msg.dim ~= "" then
      dim = parse_dim(msg.dim)
      if not dim then return nil, "неизвестное измерение" end
    end
    local w, err = add(ctx, { name = type(msg.name) == "string" and msg.name or "", x = x, y = y, z = z, dim = dim,
      kind = parse_kind(msg.kind), author = player or "КПК" })
    if not w then return nil, err end
    return view(w, player and pos_of(ctx, player, false))
  end,
  remove = function(ctx, msg)
    local w = remove(ctx, msg.id)
    if not w then return nil, "нет такой метки" end
    return { removed = w.id, name = w.name }
  end,
  rename = function(ctx, msg)
    local w, err = radio_item(ctx, msg)
    if not w then return nil, err end
    local name = clean_name(msg.name)
    if name == "" then return nil, "пустое имя" end
    w.name = name
    ctx.save()
    return { id = w.id, name = name }
  end,
}

-- ---------- нейросеть ----------
local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end
local S = function(d) return { type = "string", description = d } end
local N = function(d) return { type = "integer", description = d } end

function M.tools()
  return {
    { name = "wp_list", description = "Общие метки экипажа (дом, шахта, портал, точки смерти…): номер, имя, координаты, измерение и маршрут от спросившего игрока (ближние первыми).",
      parameters = obj({ query = S("часть имени, необязательно"), kind = S("home|mine|portal|death|other, необязательно") }) },
    { name = "wp_add", description = "Поставить общую метку. Без x/y/z — там, где сейчас стоит спросивший игрок; с x, y, z — по координатам (dim — измерение, по умолчанию то, где игрок).",
      parameters = obj({ name = S("имя метки, до 32 символов"), kind = S("home|mine|portal|death|other (необязательно: угадаю по имени)"),
        x = N("X, необязательно"), y = N("Y, необязательно"), z = N("Z, необязательно"),
        dim = S("измерение: minecraft:overworld | minecraft:the_nether | minecraft:the_end или id мода, необязательно") }, { "name" }) },
    { name = "wp_remove", description = "Удалить метку по номеру (id из wp_list) или точному имени. Удаляй только по просьбе игрока.",
      parameters = obj({ id = N("номер метки"), name = S("имя, если номер неизвестен") }) },
    { name = "wp_route", description = "Куда идти спросившему игроку до метки: расстояние, сторона света, выше/ниже; из другого измерения — через Незер.",
      parameters = obj({ id = N("номер метки"), name = S("имя или часть имени") }) },
  }
end

function M.run_tool(ctx, name, a, tctx)
  local player = valid_player(tctx.player) and tctx.player or nil
  if name == "wp_list" then
    local from = player and pos_of(ctx, player, true)
    local kind = a.kind and parse_kind(a.kind)
    local q = a.query and norm(a.query) or ""
    local items, total = sorted_views(ctx, from, function(w)
      return (not kind or w.kind == kind) and (q == "" or norm(w.name):find(q, 1, true) ~= nil)
    end, 40)
    for _, it in ipairs(items) do it.dir_s, it.dim, it.kind = nil, nil, nil end   -- короче для модели
    return { player = player, player_pos = from and (coords(from) .. " " .. dim_name(from.dim)) or nil,
      count = total, shown = #items, waypoints = items }
  elseif name == "wp_add" then
    if a.x ~= nil or a.y ~= nil or a.z ~= nil then
      local x, y, z = int(a.x, -LIMIT_XZ, LIMIT_XZ), int(a.y, Y_MIN, Y_MAX), int(a.z, -LIMIT_XZ, LIMIT_XZ)
      if not (x and y and z) then return "отказ: нужны целые x, y, z (y от -2048 до 4096)" end
      local from = player and pos_of(ctx, player, false)
      local dim = OVER
      if a.dim ~= nil and a.dim ~= "" then
        dim = parse_dim(a.dim)
        if not dim then return "отказ: неизвестное измерение " .. tostring(a.dim) end
      elseif from then dim = from.dim end
      local w, err = add(ctx, { name = a.name, x = x, y = y, z = z, dim = dim, kind = parse_kind(a.kind), author = player or "ЛОЦМАН" })
      if not w then return "отказ: " .. tostring(err) end
      return { added = view(w, from) }
    end
    local w, err = add_here(ctx, player, a.name, parse_kind(a.kind))
    if not w then return "отказ: " .. tostring(err) end
    return { added = view(w, pos_of(ctx, player, false)) }
  elseif name == "wp_remove" then
    local w = find(ctx, a.id or a.name)
    if a.id == nil and w and norm(w.name) ~= norm(a.name) then return "отказ: точного имени нет, похожая — «" .. w.name .. "» (№" .. w.id .. ")" end
    if not w then return "нет такой метки" end
    remove(ctx, w.id)
    return { removed = w.id, name = w.name }
  elseif name == "wp_route" then
    local w = find(ctx, a.id or a.name)
    if not w then return "нет такой метки" end
    if not player then return "не знаю, кто спрашивает — назови метку и координаты: " .. coords(w) .. " " .. dim_name(w.dim) end
    local from, err = pos_of(ctx, player, true)
    if not from then return { waypoint = view(w), note = why_no_pos(player, err) } end
    return view(w, from)
  end
  return "нет такого инструмента"
end

-- для тестов
M._t = { parse_coords = parse_coords, parse_dim = parse_dim, route = route, geo = geo, norm = norm, find = find,
  check_deaths = check_deaths, view = view, V = V, guess_kind = guess_kind }

return M
