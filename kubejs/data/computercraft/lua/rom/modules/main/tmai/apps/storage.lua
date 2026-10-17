-- tmai.apps.storage — «Склад»: всё, что лежит в сундуках проводной сети компьютера ЛОЦМАНа и в МЭ-сети (ME Bridge),
-- без нейросети и фразами через неё. Части:
--   ИНДЕКС — в tick по частям: МЭ одним getItems + по нескольку инвентарей list(); названия и теги — из МЭ или
--     getItemDetail только для новых id. Поиск по названию (кириллица) и ID.
--   ВЫДАЧА — Enter на предмете → сколько → сундук «Выдача» (pushItems из сундуков, exportItem МЭ); не хватает —
--     «Заказать в МЭ» (me.request_craft, крупный заказ — «да КОД» в чате).
--   НАБЛЮДЕНИЕ — «железо — не меньше 64» → тревога storage.low.<id> (снимается сама).
--   СУНДУКИ — у каждого номер (№7) и имя, данное через ЛОЦМАНа («руды»); распознаватель «какой сундук»: имя, номер,
--     «новый/последний подключённый», «пустой», «где лежит X» (неоднозначно — список вариантов, переспросить).
--   СОРТИРОВКА — сундук «Приёмка»: всё из него раскладывается порциями: правило («что» → «куда») → сундук, где этот
--     предмет уже лежит → МЭ («лишнее — в МЭ») → сундук «Разное»; не вышло — остаётся, тревога storage.intake.
--     «Разобрать сундук» — то же для любого сундука.
--   ПЕРЕПЛАВКА — ванильные печи/плавильные печи/коптильни в сети (вид печи зависит от грани с модемом: сверху —
--     загрузка, снизу — выход и топливо, сбоку — топливо). Задания «переплавить N X / всю руду»: раздать по печам,
--     подкинуть топливо со склада, забрать результат на склад; общая очередь с конвейерами.
--   КОНВЕЙЕРЫ — постоянные правила: из сундука → переплавить | переложить | разложить | в МЭ → куда (фильтр).
-- Складом (источником выдачи) НЕ считаются: ядро ИИ, Ящик памяти (как в app.lua), «Выдача», «Приёмка», сундуки
-- конвейеров, печи, МЭ-мост; машины — по умолчанию нет. Электропечи Mekanism — своя периферия без переноса предметов,
-- их ЛОЦМАН не загружает.
-- Инструменты: storage_find/take/watch, storage_chests/name_chest, storage_sort_rule/sort_now,
-- storage_smelt/smelt_status/smelt_stop, storage_flow_add/flow_list/flow_remove. КПК: act = find | take | low.

local u8 = require("tmai.u8")
local text = require("tmai.text")
local util = require("tmai.util")
local json = require("tmai.json")

local A = { id = "storage", title = "Склад", short = "Склад", order = 40, monitor = true, every = 2 }

local C = {
  RESCAN = 30,           -- секунд между проходами индекса (если ничего не менялось)
  LIST_PER_TICK = 6,     -- инвентарей индекса за tick
  DETAIL_PER_TICK = 4,   -- getItemDetail за tick (новые id)
  TICK_CALLS = 18,       -- вызовов периферии за tick на приёмку, конвейеры, печи
  MAX_TAKE = 4096, MAX_WATCH = 40, MAX_RULES = 50, MAX_FLOWS = 20, NAMES_MAX = 1500, RESULTS_MAX = 30,
  NEW_WINDOW = 600,      -- «новый сундук»: подключён за последние 10 минут
  STUCK_RETRY = 60,      -- некуда положить — повтор через минуту
  IDLE_POLL = 6,         -- пустой источник — проверять раз в 6 с
  FEED = 16,             -- за раз в печь
  FUEL_LOW = 8, FUEL_FILL = 16,
  STALL = 90,            -- вход печи не уменьшается столько секунд — «не плавит»
  SMELT_IDLE = 180,      -- задание без движения столько секунд — закончить
  NAMES_PATH = util.DATA_DIR .. "/apps/storage_names.json",
}
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local MACHINE = { "furnace", "smoker", "brewing", "hopper", "dropper", "dispenser", "crafter" }
local FURN = { ["minecraft:furnace"] = "furnace", ["minecraft:blast_furnace"] = "blast", ["minecraft:smoker"] = "smoker" }
local FURN_LABEL = { furnace = "печь", blast = "плавильная печь", smoker = "коптильня" }
local FUELS = { "minecraft:coal", "minecraft:charcoal", "minecraft:coal_block", "minecraft:dried_kelp_block", "minecraft:blaze_rod" }
local FUEL_SET = {}
for _, f in ipairs(FUELS) do FUEL_SET[f] = true end
local BLOCK_FUEL = { ["minecraft:coal_block"] = 4, ["minecraft:dried_kelp_block"] = 4 }
-- слоты вида печи (с 1) по роли: full — все три (если мод даёт), bottom — модем снизу, in — сверху, fuel — сбоку
local SLOTS = { full = { input = 1, fuel = 2, out = 3 }, bottom = { out = 1, fuel = 2 }, ["in"] = { input = 1 },
  fuel = { fuel = 1 }, unknown = {} }
local VIEW_LABEL = { full = "всё", bottom = "выход и топливо", ["in"] = "загрузка", fuel = "топливо", unknown = "проверяю" }
local KIND_RANK = { id = 1, tag = 2, cat = 3, mod = 4 }
local ACTIONS = { ["переплавить"] = "smelt", ["переплавлять"] = "smelt", ["плавить"] = "smelt", ["плавка"] = "smelt",
  ["smelt"] = "smelt", ["переложить"] = "move", ["перекладывать"] = "move", ["перенести"] = "move",
  ["переносить"] = "move", ["move"] = "move", ["разложить"] = "sort", ["раскладывать"] = "sort",
  ["сортировать"] = "sort", ["sort"] = "sort", ["в мэ"] = "me", ["мэ"] = "me", ["me"] = "me" }
local ACTION_WORD = { smelt = "переплавить", move = "переложить", sort = "разложить", me = "в МЭ" }

local FOOD_RAW = { ":beef$", ":porkchop$", ":chicken$", ":mutton$", ":rabbit$", ":cod$", ":salmon$", ":potato$", ":kelp$" }
local CATS = {
  { key = "руды", alias = { "руда", "руду", "руд", "рудой", "ore", "ores", "сырье" },
    tags = { "c:ores", "c:raw_materials" }, ids = { "_ore$", "[:_]raw_" }, not_ids = { "_block$" } },
  { key = "слитки", alias = { "слиток", "слитков", "ingots" }, tags = { "c:ingots", "c:nuggets" }, ids = { "_ingot$", "_nugget$" } },
  { key = "самоцветы", alias = { "самоцвет", "кристаллы", "gems" }, tags = { "c:gems" },
    ids = { ":diamond$", ":emerald$", "_gem$", ":quartz$", "amethyst_shard$", "lapis_lazuli$" } },
  { key = "пыль", alias = { "пыли", "порошки", "dusts" }, tags = { "c:dusts" }, ids = { "_dust$" } },
  { key = "блоки ресурсов", alias = { "блоки металлов" }, tags = { "c:storage_blocks" } },
  { key = "еда", alias = { "еду", "еды", "пища", "пищу", "food" }, tags = { "c:foods" },
    ids = { ":beef$", ":porkchop$", ":chicken$", ":mutton$", ":rabbit$", ":cod$", ":salmon$", ":potato$", "cooked_",
      "bread$", "apple$", "carrot$", "stew$", "_pie$", "cookie$", "melon_slice$", "berries$" } },
  { key = "семена", alias = { "семя", "семян", "seeds" }, tags = { "c:seeds" }, ids = { "_seeds$" } },
  { key = "урожай", alias = { "культуры", "овощи", "crops" }, tags = { "c:crops", "c:mushrooms" },
    ids = { ":wheat$", ":carrot$", ":potato$", ":beetroot$" } },
  { key = "саженцы", alias = { "саженец", "saplings" }, tags = { "minecraft:saplings" }, ids = { "_sapling$", "_propagule$" } },
  { key = "дерево", alias = { "древесина", "древесину", "бревна", "доски", "дрова", "logs" },
    tags = { "minecraft:logs", "minecraft:planks", "c:stripped_logs", "c:stripped_woods" }, ids = { "_log$", "_planks$", "_wood$", "_stem$" } },
  { key = "камень", alias = { "камни", "камня", "булыжник", "булыжника", "stone" },
    tags = { "c:stones", "c:cobblestones", "minecraft:stone_bricks", "c:netherracks", "c:end_stones", "c:obsidians" },
    ids = { "[:_]stone$", "cobblestone$", ":deepslate$", ":andesite$", ":diorite$", ":granite$", ":tuff$", ":netherrack$" } },
  { key = "песок", alias = { "песка", "песку", "sand" }, tags = { "c:sands" }, ids = { "[:_]sand$" } },
  { key = "блоки", alias = { "стройматериалы", "строительные блоки" },
    tags = { "c:stones", "c:cobblestones", "minecraft:planks", "minecraft:logs", "c:glass_blocks", "c:glass_panes", "minecraft:wool",
      "minecraft:terracotta", "c:glazed_terracottas", "c:concretes", "c:concrete_powders", "c:bricks", "minecraft:stairs",
      "minecraft:slabs", "minecraft:walls", "c:fences", "c:fence_gates", "c:sands", "c:gravels" },
    ids = { "_stairs$", "_slab$", "_wall$", "_planks$", "bricks$", "glass$", "_wool$", "terracotta$", "concrete$" } },
  { key = "инструменты", alias = { "инструмент", "tools" },
    tags = { "c:tools/mining_tool", "minecraft:pickaxes", "minecraft:axes", "minecraft:shovels", "minecraft:hoes", "c:tools/shear",
      "c:tools/fishing_rod", "c:tools/brush", "c:tools/wrench", "c:tools/igniter" },
    ids = { "_pickaxe$", "_axe$", "_shovel$", "_hoe$", ":shears$", "fishing_rod$", "flint_and_steel$" } },
  { key = "оружие", alias = { "оружия", "weapons" },
    tags = { "minecraft:swords", "c:tools/melee_weapon", "c:tools/ranged_weapon", "c:tools/bow", "c:tools/crossbow", "c:tools/spear",
      "c:tools/mace", "c:tools/shield", "minecraft:arrows" },
    ids = { "_sword$", "[:_]bow$", "crossbow$", ":trident$", ":shield$", ":mace$", "arrow$" } },
  { key = "броня", alias = { "броню", "брони", "доспехи", "armor" },
    tags = { "c:armors", "minecraft:head_armor", "minecraft:chest_armor", "minecraft:leg_armor", "minecraft:foot_armor" },
    ids = { "_helmet$", "_chestplate$", "_leggings$", "_boots$" } },
  { key = "зелья", alias = { "зелье", "potions" }, tags = { "c:potions" }, ids = { "potion$" } },
  { key = "красители", alias = { "краски", "dyes" }, tags = { "c:dyes" }, ids = { "_dye$" } },
  { key = "с мобов", alias = { "добыча с мобов", "лут", "мобы" },
    tags = { "c:bones", "c:feathers", "c:leathers", "c:strings", "c:slime_balls", "c:gunpowders", "c:ender_pearls" },
    ids = { ":bone$", ":feather$", ":leather$", ":string$", "slime_ball$", ":gunpowder$", "ender_pearl$", "rotten_flesh$", "spider_eye$", "blaze_rod$" } },
}
local CAT_BY = {}
for _, c in ipairs(CATS) do
  CAT_BY[u8.lower(c.key)] = c
  for _, a in ipairs(c.alias) do CAT_BY[u8.lower(a)] = c end
end

local ROLE_LABEL = { store = "склад", off = "исключён", core = "ядро ИИ", memory = "Ящик памяти", issue = "Выдача",
  intake = "Приёмка", flow = "конвейер", furnace = "печь", bridge = "МЭ-мост", machine = "машина", unmarked = "не отмечен" }
local ROLE_DESC = {
  core = "Ядро ИИ — не склад.",
  memory = "Ящик памяти — для записок и деталей ремонта, со склада не выдаётся.",
  issue = "Сюда склад кладёт выданные предметы.",
  intake = "Всё, что сюда положат, ЛОЦМАН разложит сам.",
  flow = "Участвует в конвейере — не источник выдачи.",
  furnace = "Печь — для переплавки (модем сверху — загрузка, снизу — выход и топливо).",
  bridge = "МЭ-мост: его запасы — строка «МЭ-сеть».",
}

local S = {}
local function reset_state()
  S = { index = nil, pass = nil, passes = 0, names = {}, me_names = {}, lname = {}, sizes = {}, need = {}, tags = {},
    results = {}, query = "", msg = nil, offer = nil, pick = nil, soon = false, last_start = -1e12, low = {},
    names_dirty = false, dirty = false, src_state = {}, fstate = {}, sort_job = nil, tasks = {}, vstate = {},
    views = {}, drain = false, nosmelt = {}, stall_ids = {}, smelt_note = nil, intake_info = nil, tickn = 0,
    smelt_rr = 0 }
end
reset_state()

-- ---------- мелочи ----------
local function now() return util.now() end
local function norm(s) return u8.lower(u8.trim(tostring(s or ""))) end
local function valid_id(id)
  return type(id) == "string" and id:match("^[a-z0-9_%.%-]+:[a-z0-9_/%.%-]+$") ~= nil
end
local function nick(p)   -- ник игрока или nil (как who.valid)
  if type(p) == "string" and #p >= 3 and #p <= 16 and p:match("^[A-Za-z0-9_]+$") then return p end
  return nil
end
-- 950 → "950", 1234 → "1.2к", 56789 → "56к", 3.4e6 → "3.4м"
local function fmt(n)
  n = math.floor(tonumber(n) or 0)
  if n < 1000 then return tostring(n) end
  local function one(x, suf)
    if x < 10 then return (string.format("%.1f", x):gsub("%.0$", "")) .. suf end
    return tostring(math.floor(x)) .. suf
  end
  if n < 1000000 then return one(n / 1000, "к") end
  if n < 1000000000 then return one(n / 1000000, "м") end
  return one(n / 1000000000, "млрд")
end
local function pct(a, b)
  a, b = tonumber(a), tonumber(b)
  if not a or not b or b <= 0 then return nil end
  return math.floor(a * 100 / b + 0.5)
end
local function pretty(id) return ((id:match(":(.+)$") or id):gsub("[_/]", " ")) end
local function short_inv(n) return n:match(":(.+)$") or n end
local function name_of(id, fallback) return S.names[id] or S.me_names[id] or fallback or pretty(id) end
local function hay(id)
  local h = S.lname[id]
  if not h then h = u8.lower(name_of(id) .. " " .. id); S.lname[id] = h end
  return h
end
local function wait(t) if sleep then sleep(t) end end
local function is_inv(n) return type(n) == "string" and n ~= "" and peripheral.hasType(n, "inventory") end
local function sorted_keys(t)
  local o = {}
  for k in pairs(t) do if type(k) == "number" then o[#o + 1] = k end end
  table.sort(o)
  return o
end
local function tagset(t)
  local s = {}
  if type(t) ~= "table" then return s end
  for k, v in pairs(t) do
    if type(k) == "string" and v then s[k] = true elseif type(v) == "string" then s[v] = true end
  end
  return s
end
-- бюджет вызовов периферии: B = { left = N }; nil — без ограничения
local function spend(B)
  if not B then return true end
  if B.left <= 0 then return false end
  B.left = B.left - 1
  return true
end
local function call(B, name, method, ...)
  if not spend(B) then return false, "budget" end
  return pcall(peripheral.call, name, method, ...)
end
local function say_msg(s, fg) S.msg = { text = s, fg = fg } end
local function cut(t, w) if t:sub(1, #w) == w then return t:sub(#w + 1) end end

-- ---------- роли инвентарей ----------
-- Ящик памяти — та же логика, что в app.lua: из настройки, иначе вплотную к компьютеру, иначе первый в сети.
local function memory_box_name(ctx)
  local want = (ctx.cfg() or {}).memory_box or ""
  if want ~= "" and peripheral.hasType(want, "inventory") then return want end
  local remote
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") and not peripheral.hasType(n, "kubejs:ai_core") then
      if SIDES[n] then return n end
      remote = remote or n
    end
  end
  return remote
end

local function ptype(n)
  local ok, t = pcall(peripheral.getType, n)
  return ok and type(t) == "string" and t or ""
end

local function furnace_kind(n)
  local t = ptype(n)
  if FURN[t] then return FURN[t] end
  if t ~= "" and t:find(":", 1, true) and not t:find("furnace", 1, true) and not t:find("smoker", 1, true) then return nil end
  if n:find("blast_furnace", 1, true) then return "blast" end
  if n:find("smoker", 1, true) then return "smoker" end
  if n:find("minecraft:furnace", 1, true) then return "furnace" end
  return nil
end

local function is_machine(n)
  if peripheral.hasType(n, "energy_storage") then return true end
  local s = ptype(n) .. " " .. n
  for _, m in ipairs(MACHINE) do if s:find(m, 1, true) then return true end end
  return false
end

local function flow_chests(ctx)
  local s = {}
  for _, f in ipairs(ctx.data.flows or {}) do
    s[f.from] = true
    if f.to ~= "me" and f.to ~= "store" then s[f.to] = true end
  end
  return s
end

-- Все инвентари сети с ролью: { {name, role, hard, side}, … } (не ждёт).
local function classify(ctx)
  local out = {}
  local mem = memory_box_name(ctx)
  local d = ctx.data
  local inv = d.inv or {}
  local fl = flow_chests(ctx)
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") then
      local role, hard
      if peripheral.hasType(n, "kubejs:ai_core") then role, hard = "core", true
      elseif peripheral.hasType(n, "me_bridge") then role, hard = "bridge", true
      elseif n == mem then role, hard = "memory", true
      elseif n == d.issue then role, hard = "issue", true
      elseif n == d.intake then role, hard = "intake", true
      elseif fl[n] then role, hard = "flow", true
      elseif furnace_kind(n) then role, hard = "furnace", true
      elseif inv[n] == false then role = "off"
      elseif inv[n] == true then role = "store"
      elseif d.mode == "chosen" then role = "unmarked"
      elseif is_machine(n) then role = "machine"
      else role = "store" end
      out[#out + 1] = { name = n, role = role, hard = hard, side = SIDES[n] == true }
    end
  end
  return out
end

local function role_of(ctx, n)
  for _, c in ipairs(classify(ctx)) do if c.name == n then return c.role end end
  return nil
end

local function store_set(ctx)
  local s = {}
  for _, c in ipairs(classify(ctx)) do if c.role == "store" then s[c.name] = true end end
  return s
end

local function has_bridge()
  for _, n in ipairs(peripheral.getNames()) do if peripheral.hasType(n, "me_bridge") then return true end end
  return false
end

local function use_me(ctx) return ctx.me ~= nil and ctx.data.use_me ~= false end

-- ---------- сундуки: номера, имена, «последний подключённый», распознаватель ----------
local Chest = {}

-- Номера и время первого появления (без ожидания). Первый запуск: всё, что уже было, — «давно».
function Chest.sync(ctx)
  local d = ctx.data
  local first = not d.seen_init
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") then
      if not d.nums[n] then d.next_num = (tonumber(d.next_num) or 0) + 1; d.nums[n] = d.next_num; S.dirty = true end
      if d.seen[n] == nil then d.seen[n] = first and 0 or now(); S.dirty = true end
    end
  end
  if first then d.seen_init = true; S.dirty = true end
  if S.tickn % 150 == 0 then      -- давно отключённые: номера и метки «новый» не копить без конца
    local n = 0
    for _ in pairs(d.nums) do n = n + 1 end
    if n > 300 then
      for k in pairs(d.nums) do
        if not peripheral.hasType(k, "inventory") and not d.labels[k] then d.nums[k], d.seen[k], d.fview[k] = nil, nil, nil end
      end
      S.dirty = true
    end
  end
end

-- Событие peripheral: новый инвентарь (без ожидания).
function Chest.attached(ctx, n)
  if not is_inv(n) then return end
  local d = ctx.data
  if d.seen[n] == nil then d.seen[n] = now() end
  if not d.nums[n] then d.next_num = (tonumber(d.next_num) or 0) + 1; d.nums[n] = d.next_num end
  S.dirty = true
end

-- «Ссылка» на сундук для правил и текста: имя, данное игроком, иначе №N.
function Chest.ref(ctx, n)
  if n == "me" then return "МЭ" end
  if n == "store" then return "склад" end
  local lb = ctx.data.labels[n]
  if lb then return lb end
  local num = ctx.data.nums[n]
  return num and ("№" .. num) or n
end

-- Как показать: «руды» №7 / №7 chest_12.
function Chest.title(ctx, n)
  if n == "me" then return "МЭ" end
  if n == "store" then return "склад" end
  local lb = ctx.data.labels[n]
  local num = ctx.data.nums[n]
  if lb then return "«" .. lb .. "»" .. (num and (" №" .. num) or "") end
  return (num and ("№" .. num .. " ") or "") .. short_inv(n)
end

-- Что в основном лежит (по индексу).
function Chest.top(n)
  local t = S.index and S.index.tops and S.index.tops[n]
  if not t then return "" end
  local parts = {}
  for _, x in ipairs(t) do parts[#parts + 1] = name_of(x.id) .. " " .. fmt(x.n) end
  return table.concat(parts, ", ")
end

function Chest.brief(ctx, n, role)
  local st = S.index and S.index.invs[n]
  local seen = tonumber(ctx.data.seen[n]) or 0
  return { num = ctx.data.nums[n], name = ctx.data.labels[n], id = n, role = ROLE_LABEL[role or role_of(ctx, n) or ""] or "?",
    fill = st and (st.used .. "/" .. st.size) or nil, top = Chest.top(n) ~= "" and Chest.top(n) or nil,
    new = (seen > 0 and now() - seen < C.NEW_WINDOW) or nil }
end

local function candidates(ctx, opts)
  local out = {}
  for _, c in ipairs(classify(ctx)) do
    if c.role ~= "core" and c.role ~= "bridge" and (opts.any or c.role ~= "memory") then out[#out + 1] = c end
  end
  return out
end

local resolve   -- поиск предмета (ниже)

-- Какой сундук имел в виду игрок. q: имя периферии, имя от игрока («руды»), номер («7», «№7», «сундук 7»),
-- «новый / последний подключённый», «пустой», «где лежит X». opts: me=true («МЭ»), store=true («склад»), any=true.
-- -> имя | nil, ошибка, варианты (список имён для переспроса)
function Chest.which(ctx, q, opts)
  opts = opts or {}
  local raw = u8.trim(tostring(q or ""))
  local s = norm(raw)
  if s == "" then return nil, "не указан сундук" end
  if opts.me and (s == "мэ" or s == "me" or s == "мэ-сеть" or s == "мэ сеть" or s == "в мэ" or s == "ae2") then return "me" end
  if opts.store and (s == "склад" or s == "на склад" or s == "в склад" or s == "по складу") then return "store" end
  local list = candidates(ctx, opts)
  for _, c in ipairs(list) do if c.name == raw or c.name == s then return c.name end end
  for _, c in ipairs(list) do
    local lb = ctx.data.labels[c.name]
    if lb and norm(lb) == s then return c.name end
  end
  local t = s
  for _, w in ipairs({ "в ", "из ", "на " }) do t = cut(t, w) or t end
  for _, w in ipairs({ "сундук ", "сундука ", "сундуке ", "сундучок ", "бочка ", "бочку ", "бочке ", "ящик ", "ящика ", "ящике " }) do
    t = cut(t, w) or t
  end
  t = u8.trim(t)
  -- имя от игрока — точно
  for _, c in ipairs(list) do
    local lb = ctx.data.labels[c.name]
    if lb and norm(lb) == t then return c.name end
  end
  -- номер
  local num = t:match("^№[ \t]*([0-9]+)$") or t:match("^#[ \t]*([0-9]+)$") or t:match("^([0-9]+)$") or t:match("^номер[ \t]+([0-9]+)$")
  if num then
    for _, c in ipairs(list) do if ctx.data.nums[c.name] == tonumber(num) then return c.name end end
    return nil, "нет сундука №" .. num
  end
  -- короткое имя периферии (chest_12)
  for _, c in ipairs(list) do if short_inv(c.name) == t then return c.name end end
  -- «новый / последний подключённый»
  if t:find("нов", 1, true) or t:find("последн", 1, true) or t:find("только что", 1, true) or t:find("свеж", 1, true) then
    local best, recent = nil, {}
    for _, c in ipairs(list) do
      local sn = tonumber(ctx.data.seen[c.name]) or 0
      if not best or sn > (tonumber(ctx.data.seen[best]) or 0) then best = c.name end
      if sn > 0 and now() - sn < C.NEW_WINDOW then recent[#recent + 1] = { n = c.name, t = sn } end
    end
    table.sort(recent, function(a, b) return a.t > b.t end)
    if #recent == 1 then return recent[1].n end
    if #recent > 1 then
      local o = {}
      for _, r in ipairs(recent) do o[#o + 1] = r.n end
      return nil, "за последние 10 минут подключено несколько сундуков — какой?", o
    end
    if best and (tonumber(ctx.data.seen[best]) or 0) > 0 then return best end
    return nil, "новых сундуков не видно (подключены давно) — назовите номер", nil
  end
  -- «пустой»
  if t:find("пуст", 1, true) then
    local o = {}
    for _, c in ipairs(list) do
      local st = S.index and S.index.invs[c.name]
      if c.role == "store" and st and st.used == 0 then o[#o + 1] = c.name end
    end
    if #o == 1 then return o[1] end
    if #o == 0 then return nil, "пустых сундуков нет" end
    return nil, "пустых сундуков несколько — какой?", o
  end
  -- «где лежит X»
  local item = t:match("^где[ \t]+лежит[ \t]+(.+)$") or t:match("^где[ \t]+лежат[ \t]+(.+)$") or t:match("^где[ \t]+(.+)$")
    or t:match("^с[ \t]+(.+)$") or t:match("^в котором[ \t]+(.+)$")
  if item then
    local id = resolve(item)
    local r = id and S.index and S.index.items[id]
    if not r then return nil, "не нашёл «" .. item .. "» в сундуках" end
    local w = {}
    for inv, n in pairs(r.where) do w[#w + 1] = { n = inv, c = n } end
    table.sort(w, function(a, b) return a.c > b.c end)
    if #w == 1 then return w[1].n end
    if #w == 0 then return nil, "«" .. name_of(id) .. "» лежит только в МЭ" end
    local o = {}
    for _, x in ipairs(w) do o[#o + 1] = x.n end
    return nil, "«" .. name_of(id) .. "» лежит в нескольких сундуках — в каком?", o
  end
  -- имя от игрока — частично
  local part = {}
  for _, c in ipairs(list) do
    local lb = ctx.data.labels[c.name]
    if lb and (norm(lb):find(t, 1, true) or t:find(norm(lb), 1, true)) then part[#part + 1] = c.name end
  end
  if #part == 1 then return part[1] end
  if #part > 1 then return nil, "подходит несколько сундуков — какой?", part end
  local o = {}
  for i = 1, math.min(8, #list) do o[#o + 1] = list[i].name end
  return nil, "не нашёл сундук «" .. raw .. "»", o
end

function Chest.rename(ctx, n, label)
  label = u8.trim(tostring(label or ""))
  if text.len(label) > 24 then label = text.sub(label, 1, 24) end
  if label == "" then ctx.data.labels[n] = nil; ctx.save(); return true end
  if label:match("^[0-9]+$") or label:sub(1, 2) == "№" then return nil, "имя не должно быть номером" end
  for other, lb in pairs(ctx.data.labels) do
    if other ~= n and norm(lb) == norm(label) and is_inv(other) then
      return nil, "имя «" .. label .. "» уже у " .. Chest.title(ctx, other)
    end
  end
  ctx.data.labels[n] = label
  ctx.save()
  return true
end

-- Варианты для переспроса (нейросети).
local function options(ctx, list)
  local o = {}
  for i = 1, math.min(8, #(list or {})) do o[#o + 1] = Chest.brief(ctx, list[i]) end
  return o
end

-- ---------- индекс (проход по частям) ----------
local function rec_of(p, id)
  local r = p.items[id]
  if not r then r = { id = id, chest = 0, me = 0, where = {} }; p.items[id] = r end
  return r
end

local function start_pass(ctx)
  local q = {}
  for _, c in ipairs(classify(ctx)) do if c.role == "store" then q[#q + 1] = c.name end end
  S.pass = { queue = q, qi = 1, inflight = 0, me_started = false, me_busy = false, items = {}, invs = {},
    slots_used = 0, slots_total = 0, chest_total = 0, me_total = 0, failed = false, me_on = false,
    size_refresh = S.passes % 10 == 0 }
  S.soon = false
  S.last_start = now()
end

local function scan_me(ctx, p)
  p.me_started, p.me_busy = true, true
  local me = ctx.me
  if use_me(ctx) then
    local items, err = me.items()
    if S.pass ~= p then return end
    if items then
      p.me_on = true
      for i, it in ipairs(items) do
        local id = it.name
        local n = tonumber(it.count or it.amount) or 0
        if type(id) == "string" and n > 0 then
          local r = rec_of(p, id)
          r.me = r.me + n
          if it.isCraftable then r.craftable = true end
          p.me_total = p.me_total + n
          if type(it.displayName) == "string" and it.displayName ~= "" and S.me_names[id] ~= it.displayName then
            S.me_names[id] = it.displayName
            S.lname[id] = nil
          end
          if it.tags and not S.tags[id] then S.tags[id] = tagset(it.tags) end
        end
        if i % 1000 == 0 then util.yield() end
      end
      local st = me.status()
      if type(st) == "table" and st.connected then p.me_used, p.me_max = st.item_storage_used, st.item_storage_max end
    elseif has_bridge() then
      p.me_failed, p.me_err = true, err     -- мост есть, сеть лежит: индекс неполный, без ложных тревог «мало»
    end
  end
  p.me_busy = false
end

local function scan_inv(p, inv)
  p.inflight = p.inflight + 1
  local ok, list = pcall(peripheral.call, inv, "list")
  local size = S.sizes[inv]
  if size == nil or p.size_refresh then
    local oks, sz = pcall(peripheral.call, inv, "size")
    size = oks and tonumber(sz) or 0
    S.sizes[inv] = size
  end
  p.inflight = p.inflight - 1
  if S.pass ~= p then return end
  if not ok or type(list) ~= "table" then p.failed = true; return end
  local used = 0
  for slot, it in pairs(list) do
    if type(it) == "table" and type(it.name) == "string" then
      local n = tonumber(it.count) or 0
      local r = rec_of(p, it.name)
      r.chest = r.chest + n
      r.where[inv] = (r.where[inv] or 0) + n
      if not r.loc then r.loc = { inv = inv, slot = slot } end
      p.chest_total = p.chest_total + n
      used = used + 1
      if (not S.names[it.name] and not S.me_names[it.name]) and not S.need[it.name] then
        S.need[it.name] = { inv = inv, slot = slot }
      end
    end
  end
  p.invs[inv] = { used = used, size = size }
  p.slots_used = p.slots_used + used
  p.slots_total = p.slots_total + size
end

-- Названия и теги новых предметов: getItemDetail, не больше limit вызовов.
local function detail_step(limit)
  local todo = {}
  for id, loc in pairs(S.need) do
    todo[#todo + 1] = { id = id, loc = loc }
    if #todo >= limit then break end
  end
  for _, t in ipairs(todo) do
    S.need[t.id] = nil
    if not S.names[t.id] or not S.tags[t.id] then
      local ok, d = pcall(peripheral.call, t.loc.inv, "getItemDetail", t.loc.slot)
      if ok and type(d) == "table" and d.name == t.id then
        if type(d.displayName) == "string" and d.displayName ~= "" and not S.names[t.id] then
          S.names[t.id] = d.displayName
          S.lname[t.id] = nil
          S.names_dirty = true
        end
        S.tags[t.id] = tagset(d.tags)
      end
    end
  end
end

-- Теги предмета в слоте (кэш по id; один getItemDetail).
local function tags_for(B, inv, slot, id)
  if S.tags[id] then return S.tags[id] end
  if not inv or not slot then return nil end
  local ok, d = call(B, inv, "getItemDetail", slot)
  if ok and type(d) == "table" and d.name == id then
    S.tags[id] = tagset(d.tags)
    if type(d.displayName) == "string" and d.displayName ~= "" and not S.names[id] then
      S.names[id] = d.displayName; S.lname[id] = nil; S.names_dirty = true
    end
    return S.tags[id]
  end
  return nil
end

local function save_names()
  if not S.names_dirty then return end
  local n = 0
  for _ in pairs(S.names) do n = n + 1 end
  if n > C.NAMES_MAX and S.index then
    local keep = {}
    for id in pairs(S.index.items) do if S.names[id] then keep[id] = S.names[id] end end
    S.names = keep
  end
  pcall(util.save_json, C.NAMES_PATH, S.names)
  S.names_dirty = false
end

-- ---------- поиск ----------
local function variants(w)
  local out = { w }
  local L = text.len(w)
  if L >= 5 then out[2] = text.sub(w, 1, L - 1); out[3] = text.sub(w, 1, L - 2)
  elseif L == 4 then out[2] = text.sub(w, 1, 3) end
  return out
end

-- Поиск по названию и id (каждое слово — подстрока; «железо» найдёт «Железный слиток»). -> { id, … }
local function search(query, limit)
  local q = norm(query)
  if q == "" or not S.index then return {} end
  local words = {}
  for w in q:gmatch("[^ \t]+") do words[#words + 1] = { w = w, v = variants(w) } end
  local found, i = {}, 0
  for id, r in pairs(S.index.items) do
    i = i + 1
    local h = hay(id)
    local score = 0
    for _, wd in ipairs(words) do
      local s = 0
      if h:find(wd.w, 1, true) then s = 3
      else
        for k = 2, #wd.v do if h:find(wd.v[k], 1, true) then s = 1; break end end
      end
      if s == 0 then score = -1; break end
      score = score + s
    end
    if score > 0 then
      if id == q or u8.lower(name_of(id)) == q then score = score + 10 end
      found[#found + 1] = { id = id, score = score, total = r.chest + r.me }
    end
    if i % 500 == 0 then util.yield() end
  end
  table.sort(found, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.total ~= b.total then return a.total > b.total end
    return a.id < b.id
  end)
  local out = {}
  for k = 1, math.min(limit or C.RESULTS_MAX, #found) do out[k] = found[k].id end
  return out
end

-- Название или ID → id (лучшее совпадение), список кандидатов.
resolve = function(q)
  q = u8.trim(tostring(q or ""))
  if valid_id(q) then return q, { q } end
  local r = search(q, 5)
  return r[1], r
end

local function have(id)
  local r = S.index and S.index.items[id]
  return r and (r.chest + r.me) or 0
end

-- ---------- «что»: id, мод, тег, категория ----------
local Spec = {}

-- -> { kind = "any"|"id"|"tag"|"mod"|"cat", what } | nil, ошибка
function Spec.parse(s)
  local t = norm(s)
  for _, w in ipairs({ "все ", "всё ", "всю ", "весь ", "всех ", "любые ", "любой " }) do t = cut(t, u8.lower(w)) or t end
  for _, w in ipairs({ " все", " всё", " всю", " весь", " целиком" }) do
    w = u8.lower(w)
    if #t > #w and t:sub(-#w) == w then t = t:sub(1, #t - #w) end
  end
  t = u8.trim(t)
  if t == "" or t == "все" or t == "всё" or t == "любое" or t == "*" or t == "всё подряд" then return { kind = "any" } end
  local tg = cut(t, "#") or cut(t, "тег ")
  if tg then
    tg = u8.trim(tg)
    if tg:match("^[a-z0-9_%.%-]+:[a-z0-9_/%.%-]+$") then return { kind = "tag", what = tg } end
    return nil, "тег пишется так: #c:ingots"
  end
  local md = cut(t, "мод ") or t:match("^([a-z0-9_%.%-]+):$")
  if md then
    md = (u8.trim(md):gsub(":$", ""))
    if md:match("^[a-z0-9_%.%-]+$") then return { kind = "mod", what = md } end
  end
  local cat = CAT_BY[t]
  if cat then return { kind = "cat", what = cat.key } end
  if valid_id(t) then
    if t:match("^c:") or t:match("^forge:") then return { kind = "tag", what = t } end
    return { kind = "id", what = t }
  end
  local id = resolve(s)
  if id then return { kind = "id", what = id } end
  return nil, "не понял «" .. tostring(s) .. "»: название предмета, ID, мод (create:), тег (#c:ingots) или категория (руды, слитки, еда…)"
end

function Spec.label(sp)
  if not sp or sp.kind == "any" then return "всё" end
  if sp.kind == "id" then return name_of(sp.what) end
  if sp.kind == "tag" then return "#" .. sp.what end
  if sp.kind == "mod" then return sp.what .. ":" end
  return sp.what
end

-- Как записать «что» для правки (однозначно).
function Spec.text(sp)
  if not sp or sp.kind == "any" then return "всё" end
  if sp.kind == "tag" then return "#" .. sp.what end
  if sp.kind == "mod" then return sp.what .. ":" end
  return sp.what
end

function Spec.match(sp, id, tags)
  if not sp or sp.kind == "any" then return true end
  if sp.kind == "id" then return id == sp.what end
  if sp.kind == "mod" then return id:sub(1, #sp.what + 1) == sp.what .. ":" end
  if sp.kind == "tag" then return tags ~= nil and tags[sp.what] == true end
  if sp.kind == "cat" then
    local c = CAT_BY[sp.what]
    if not c then return false end
    for _, p in ipairs(c.not_ids or {}) do if id:find(p) then return false end end
    if tags then for _, tg in ipairs(c.tags) do if tags[tg] then return true end end end
    for _, p in ipairs(c.ids or {}) do if id:find(p) then return true end end
    return false
  end
  return false
end

function Spec.needs_tags(sp) return sp ~= nil and (sp.kind == "tag" or sp.kind == "cat") end

local function fuelish(id)
  return FUEL_SET[id] or Spec.match({ kind = "cat", what = "дерево" }, id, S.tags[id])
end

-- ---------- наблюдение ----------
local function watch_name(w) return name_of(w.id, w.name) end

-- Пересчитать «мало» (S.low); alerts — поднять/снять тревоги (только по надёжному индексу).
local function check_watches(ctx, alerts)
  local low = {}
  for _, w in ipairs(ctx.data.watch or {}) do
    local h = have(w.id)
    if h < w.min then low[#low + 1] = { id = w.id, name = watch_name(w), have = h, min = w.min } end
  end
  S.low = low
  if not alerts or not ctx.alert or not S.index then return end
  for _, w in ipairs(ctx.data.watch or {}) do
    local key = "storage.low." .. w.id
    local h = have(w.id)
    if h < w.min then
      if not ctx.alert.active(key) then
        ctx.alert.raise(key, "Склад: мало «" .. watch_name(w) .. "» (меньше " .. w.min .. ")", { level = "warn", app = "storage" })
      end
    elseif ctx.alert.active(key) then
      ctx.alert.clear(key, "Склад: «" .. watch_name(w) .. "» снова есть (" .. fmt(h) .. ")")
    end
  end
end

local function index_reliable() return S.index ~= nil and not S.index.partial end

local function find_watch(ctx, id)
  for i, w in ipairs(ctx.data.watch) do if w.id == id then return w, i end end
end

-- min <= 0 — убрать. -> true | nil, ошибка
local function set_watch(ctx, id, min)
  if not valid_id(id) then return nil, "неверный ID предмета" end
  min = math.floor(tonumber(min) or 0)
  local w, i = find_watch(ctx, id)
  if min <= 0 then
    if i then table.remove(ctx.data.watch, i) end
    local key = "storage.low." .. id
    if ctx.alert and ctx.alert.active(key) then ctx.alert.clear(key) end
    ctx.save()
    check_watches(ctx, false)
    return true
  end
  if min > 10000000 then min = 10000000 end
  if not w and #ctx.data.watch >= C.MAX_WATCH then return nil, "в наблюдении уже " .. C.MAX_WATCH .. " предметов" end
  if w then w.min = min; w.name = name_of(id, w.name)
  else ctx.data.watch[#ctx.data.watch + 1] = { id = id, min = min, name = name_of(id) } end
  ctx.save()
  check_watches(ctx, index_reliable())
  return true
end

-- ---------- проход целиком ----------
local function finish_pass(ctx, p)
  if S.pass ~= p then return end
  S.pass = nil
  local prev = S.index
  -- что в основном лежит в каждом сундуке (3 самых многочисленных)
  local tops = {}
  for id, r in pairs(p.items) do
    for inv, n in pairs(r.where) do
      local t = tops[inv] or {}
      tops[inv] = t
      t[#t + 1] = { id = id, n = n }
      if #t > 6 then
        table.sort(t, function(a, b) return a.n > b.n end)
        t[7] = nil
      end
    end
  end
  for _, t in pairs(tops) do
    table.sort(t, function(a, b) return a.n > b.n end)
    for k = #t, 4, -1 do t[k] = nil end
  end
  S.index = { items = p.items, total = p.chest_total + p.me_total, chest_total = p.chest_total, me_total = p.me_total,
    slots_used = p.slots_used, slots_total = p.slots_total, invs = p.invs, n_invs = #p.queue, tops = tops,
    me_on = p.me_on, me_used = p.me_used, me_max = p.me_max, me_err = p.me_err, t = now(),
    partial = p.failed or p.me_failed or (prev ~= nil and prev.me_on and not p.me_on and use_me(ctx)) }
  S.passes = S.passes + 1
  if S.query ~= "" then   -- порядок найденного не меняем (выбор на экране не уезжает), новые — в конец
    local seen, merged = {}, {}
    for _, id in ipairs(S.results) do seen[id] = true; merged[#merged + 1] = id end
    for _, id in ipairs(search(S.query, C.RESULTS_MAX)) do
      if not seen[id] and #merged < C.RESULTS_MAX then merged[#merged + 1] = id end
    end
    S.results = merged
  end
  check_watches(ctx, not S.index.partial)
  save_names()
end

local function scan_step(ctx, budget)
  if not S.pass then start_pass(ctx) end
  local p = S.pass
  if not p.me_started then
    scan_me(ctx, p)
    if S.pass ~= p then return end
  end
  local calls = 0
  while calls < budget and p.qi <= #p.queue do
    local inv = p.queue[p.qi]
    p.qi = p.qi + 1
    scan_inv(p, inv)
    if S.pass ~= p then return calls end
    calls = calls + 1
  end
  if p.qi > #p.queue and p.inflight == 0 and not p.me_busy then finish_pass(ctx, p) end
  return calls
end

-- Индекс нужен сейчас (действие, инструмент): досчитать проход, не дожидаясь tick.
local function ensure_index(ctx)
  local n = 0
  while not S.index and n < 400 do
    n = n + 1
    local p = S.pass
    if p and p.qi > #p.queue and (p.inflight > 0 or p.me_busy) then wait(0.05)   -- досчитывает tick
    else scan_step(ctx, 50) end
  end
  return S.index ~= nil
end

-- ---------- перенос ----------
local function push_error(e)
  e = tostring(e)
  if e:find("exist", 1, true) then
    return "сундуки не видят друг друга — подключите их модемами к одной проводной сети"
  end
  return e
end

local function is_full(inv)
  local ok, l = pcall(peripheral.call, inv, "list")
  local ok2, sz = pcall(peripheral.call, inv, "size")
  if not ok or not ok2 or type(l) ~= "table" then return false end
  local used = 0
  for _ in pairs(l) do used = used + 1 end
  return used >= (tonumber(sz) or 0)
end

local function adjust_index(id, moves, from_me)
  local rec = S.index and S.index.items[id]
  if not rec then return end
  local from_chests = 0
  for inv, n in pairs(moves) do
    rec.where[inv] = (rec.where[inv] or 0) - n
    if rec.where[inv] <= 0 then rec.where[inv] = nil end
    rec.chest = math.max(0, rec.chest - n)
    from_chests = from_chests + n
  end
  rec.me = math.max(0, rec.me - from_me)
  S.index.chest_total = math.max(0, S.index.chest_total - from_chests)
  S.index.me_total = math.max(0, S.index.me_total - from_me)
  S.index.total = S.index.chest_total + S.index.me_total
end

-- Взять n штук id со склада (сундуки, где больше, потом МЭ) в инвентарь target (слот to_slot или любой).
-- -> moved, { from_chests, from_me, moves, stuck (цель не приняла), err, me_ok }
local function pull_from_store(ctx, B, id, n, target, to_slot, store)
  local info = { from_chests = 0, from_me = 0, moves = {}, stuck = false }
  local need = n
  store = store or store_set(ctx)
  local rec = S.index and S.index.items[id]
  local srcs = {}
  if rec then
    for inv, c in pairs(rec.where) do if store[inv] and inv ~= target then srcs[#srcs + 1] = { inv = inv, n = c } end end
  end
  table.sort(srcs, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.inv < b.inv end)
  for _, s in ipairs(srcs) do
    if need <= 0 or info.stuck or info.err then break end
    local ok, list = call(B, s.inv, "list")
    if not ok then if list == "budget" then break end
    elseif type(list) == "table" then
      for _, slot in ipairs(sorted_keys(list)) do
        local it = list[slot]
        if need <= 0 then break end
        if type(it) == "table" and it.name == id then
          local want = math.min(need, tonumber(it.count) or 0)
          if want > 0 then
            local okp, moved = call(B, s.inv, "pushItems", target, slot, want, to_slot)
            if not okp then
              if moved ~= "budget" then info.err = push_error(moved) end
              break
            end
            moved = math.floor(tonumber(moved) or 0)
            if moved <= 0 then info.stuck = true; break end
            need = need - moved
            info.from_chests = info.from_chests + moved
            info.moves[s.inv] = (info.moves[s.inv] or 0) + moved
          end
        end
      end
    end
  end
  if need > 0 and not info.stuck and use_me(ctx) and spend(B) then
    info.me_ok = ctx.me.ready() and true or false
    if info.me_ok and (not rec or rec.me > 0 or not S.index) then
      local moved, e = ctx.me.export(id, need, target, to_slot)
      moved = math.floor(tonumber(moved) or 0)
      need = need - moved
      info.from_me = moved
      if e and moved == 0 then info.err = info.err or e end
    end
  end
  adjust_index(id, info.moves, info.from_me)
  return n - need, info
end

-- Перенести count штук id в сундук «Выдача». -> результат | nil, ошибка
local function take(ctx, id, count, player)
  player = nick(player)
  if not valid_id(id) then return nil, "неверный ID предмета" end
  count = math.floor(tonumber(count) or 0)
  if count < 1 or count > C.MAX_TAKE then return nil, "количество — от 1 до " .. C.MAX_TAKE end
  local issue = ctx.data.issue
  if type(issue) ~= "string" or issue == "" then
    return nil, "не выбран сундук «Выдача» — выберите его на вкладке «Склад»"
  end
  if not is_inv(issue) then return nil, "сундук «Выдача» (" .. issue .. ") не найден в сети" end
  if issue == memory_box_name(ctx) then return nil, "«Выдача» совпадает с Ящиком памяти — выберите другой сундук" end
  ensure_index(ctx)
  local moved, info = pull_from_store(ctx, nil, id, count, issue)
  local need = count - moved
  local res = { item = id, name = name_of(id), asked = count, moved = moved, from_chests = info.from_chests,
    from_me = info.from_me, to = issue, player = player }
  if need > 0 then
    res.missing = need
    if is_full(issue) then res.full = true
    elseif info.err then res.error = info.err
    elseif info.me_ok and ctx.me.craftable(id) then res.craftable = true end
  end
  check_watches(ctx, false)     -- «мало» на экранах сразу; тревоги — после прохода
  S.soon = true
  ctx.log("I", "take %s x%d -> %s for %s: %d", id, count, issue, tostring(player), moved)
  return res
end

local function take_text(r)
  local s = r.moved > 0 and ("Выдано " .. r.moved .. " «" .. r.name .. "» в «Выдачу»") or ("«" .. r.name .. "»: не выдано")
  if r.missing then
    if r.full then s = s .. "; «Выдача» заполнена — освободите её"
    elseif r.error then s = s .. "; " .. r.error
    elseif r.craftable then s = s .. "; не хватает " .. r.missing .. " — МЭ может сделать"
    else s = s .. "; не хватает " .. r.missing end
  end
  return s
end

local function craft(ctx, id, n, player)
  if not ctx.me then return nil, "МЭ-сеть не подключена" end
  local c = ctx.cfg() or {}
  local cfg = { craft_confirm_over = tonumber(c.craft_confirm_over) or 64,
    confirm_items = type(c.confirm_items) == "table" and c.confirm_items or {} }
  return ctx.me.request_craft(id, n, player, cfg)
end

-- ---------- сортировка: правила и раскладка ----------
local Sort = {}

local function valid_target(ctx, n)
  if n == "me" then return use_me(ctx) end
  if not is_inv(n) then return false end
  local r = role_of(ctx, n)
  return r ~= "core" and r ~= "memory" and r ~= "issue" and r ~= "intake" and r ~= "bridge" and r ~= "furnace"
end

function Sort.rule_for(ctx, B, src, slot, id)
  local rules = ctx.data.rules
  if #rules == 0 then return nil end
  local tags = S.tags[id]
  if not tags then
    for _, r in ipairs(rules) do
      if Spec.needs_tags(r) then tags = tags_for(B, src, slot, id); break end
    end
  end
  for pass = 1, 4 do
    for _, r in ipairs(rules) do
      if KIND_RANK[r.kind] == pass and r.to ~= src and Spec.match(r, id, tags) then return r end
    end
  end
  return nil
end

-- Сундуки склада, где id уже лежит (кроме src и «Разного»), больше — раньше.
local function where_chests(ctx, id, src, store)
  local rec = S.index and S.index.items[id]
  if not rec then return {} end
  local w = {}
  for inv, n in pairs(rec.where) do
    if inv ~= src and inv ~= ctx.data.misc and store[inv] then w[#w + 1] = { inv = inv, n = n } end
  end
  table.sort(w, function(a, b) return a.n > b.n end)
  local o = {}
  for i = 1, math.min(3, #w) do o[i] = w[i].inv end
  return o
end

-- Поправить индекс после переноса (до следующего прохода): из src в to ("me" — в МЭ).
local function index_move(id, src, to, n, store)
  local rec = S.index and S.index.items[id]
  if n <= 0 or not S.index then return end
  if not rec then
    if not (store[to] or to == "me") then return end
    rec = { id = id, chest = 0, me = 0, where = {} }
    S.index.items[id] = rec
  end
  if rec.where[src] then
    rec.where[src] = rec.where[src] - n
    if rec.where[src] <= 0 then rec.where[src] = nil end
    rec.chest = math.max(0, rec.chest - n)
  end
  if to == "me" then rec.me = rec.me + n
  elseif store[to] then rec.where[to] = (rec.where[to] or 0) + n; rec.chest = rec.chest + n end
end

-- Переложить стопку src[slot] (it = {name, count}). dest: "store" — правило → где уже лежит → МЭ («лишнее — в МЭ»)
-- → «Разное»; "me"; имя инвентаря. -> moved, ошибка
local function place(ctx, B, src, slot, it, dest, store)
  local left = math.floor(tonumber(it.count) or 0)
  local err
  store = store or store_set(ctx)
  local function push(to)
    if left <= 0 or not to or to == src or not is_inv(to) then return end
    local ok, n = call(B, src, "pushItems", to, slot, left)
    if ok then
      n = math.floor(tonumber(n) or 0)
      left = left - n
      index_move(it.name, src, to, n, store)
    elseif n ~= "budget" then err = push_error(n) end
  end
  local function to_me()
    if left <= 0 or not use_me(ctx) or not spend(B) then return end
    local n, e = ctx.me.import(it.name, left, src, slot)
    n = math.floor(tonumber(n) or 0)
    left = left - n
    index_move(it.name, src, "me", n, store)
    if e and n == 0 then err = err or e end
  end
  if dest == "me" then to_me()
  elseif dest ~= "store" then push(dest)
  else
    local r = Sort.rule_for(ctx, B, src, slot, it.name)
    if r then if r.to == "me" then to_me() elseif valid_target(ctx, r.to) then push(r.to) end end
    if left > 0 then
      for _, inv in ipairs(where_chests(ctx, it.name, src, store)) do push(inv); if left <= 0 then break end end
    end
    if left > 0 and ctx.data.overflow_me ~= false then to_me() end
    if left > 0 and ctx.data.misc and ctx.data.misc ~= src and is_inv(ctx.data.misc) then push(ctx.data.misc) end
  end
  return math.floor(tonumber(it.count) or 0) - left, err
end

-- Обработать источник: всё (или по фильтру) из src — «sort» по правилам, «move» в dest, «me» в МЭ.
-- st — состояние источника (что застряло). -> { items, moved, stuck, done, empty, err }
local function process_source(ctx, B, src, action, dest, filter, st)
  st.stuck = st.stuck or {}
  local ok, list = call(B, src, "list")
  if not ok then return { budget = list == "budget", err = list ~= "budget" and "нет связи с сундуком" or nil, done = false } end
  if type(list) ~= "table" then return { done = false, err = "нет связи с сундуком" } end
  local res = { items = 0, moved = 0, stuck = 0, done = true, empty = true }
  local store = store_set(ctx)
  for _, s in ipairs(sorted_keys(list)) do
    local it = list[s]
    if type(it) == "table" and type(it.name) == "string" then
      res.empty = false
      local tags = (filter and Spec.needs_tags(filter)) and tags_for(B, src, s, it.name) or S.tags[it.name]
      if not filter or Spec.match(filter, it.name, tags) then
        res.items = res.items + 1
        local sk = st.stuck[s]
        if sk and sk.id == it.name and sk.count == it.count and now() - sk.t < C.STUCK_RETRY then
          res.stuck = res.stuck + 1
        elseif B and B.left <= 0 then
          res.done = false
          break
        else
          local d = action == "me" and "me" or (action == "sort" and "store" or dest)
          local moved, err = place(ctx, B, src, s, it, d, store)
          res.moved = res.moved + moved
          if moved < it.count then
            if B and B.left <= 0 then res.done = false; break end
            st.stuck[s] = { id = it.name, count = it.count - moved, t = now() }
            res.stuck = res.stuck + 1
            res.err = res.err or err
          else
            st.stuck[s] = nil
          end
        end
      end
    end
  end
  return res
end

-- Правило из текста «что > куда». -> правило | nil, ошибка, варианты
function Sort.parse(ctx, s)
  s = u8.trim(tostring(s or ""))
  local what, to = s:match("^(.-)[ \t]*%-?>[ \t]*(.-)$")
  if not what then what, to = s:match("^(.-)[ \t]*=[ \t]*(.-)$") end
  if not what or what == "" or not to or to == "" then
    return nil, "формат: что > куда (например: слитки > №5 или руды > МЭ)"
  end
  local sp, err = Spec.parse(what)
  if not sp then return nil, err end
  if sp.kind == "any" then return nil, "«всё» — это «Разное» или «лишнее — в МЭ», а не правило" end
  local tgt, err2, opts = Chest.which(ctx, to, { me = true })
  if not tgt then return nil, err2, opts end
  if not valid_target(ctx, tgt) then return nil, "туда класть нельзя: " .. Chest.title(ctx, tgt) end
  return { kind = sp.kind, what = sp.what, to = tgt }
end

function Sort.text(ctx, r) return Spec.text(r) .. " > " .. Chest.ref(ctx, r.to) end

function Sort.add(ctx, rule, n)
  if n then
    for i, r in ipairs(ctx.data.rules) do
      if r.n == n then rule.n = n; ctx.data.rules[i] = rule; ctx.save(); return rule end
    end
  end
  if #ctx.data.rules >= C.MAX_RULES then return nil, "правил уже " .. C.MAX_RULES end
  ctx.data.rule_seq = (tonumber(ctx.data.rule_seq) or 0) + 1
  rule.n = ctx.data.rule_seq
  ctx.data.rules[#ctx.data.rules + 1] = rule
  ctx.save()
  return rule
end

function Sort.remove(ctx, n)
  for i, r in ipairs(ctx.data.rules) do
    if r.n == n then table.remove(ctx.data.rules, i); ctx.save(); return r end
  end
end

function Sort.describe(ctx, r)
  return { n = r.n, what = Spec.label(r), kind = r.kind, to = Chest.title(ctx, r.to), rule = Sort.text(ctx, r) }
end

local function src_state(name)
  local st = S.src_state[name]
  if not st then st = { stuck = {}, next_t = 0 }; S.src_state[name] = st end
  return st
end

-- Приёмка: в tick порциями.
function Sort.intake_step(ctx, B)
  local src = ctx.data.intake
  if not is_inv(src) then S.intake_info = nil; return end
  local st = src_state(src)
  if now() < st.next_t then return end
  local r = process_source(ctx, B, src, "sort", "store", nil, st)
  S.intake_info = r
  if r.empty then
    st.next_t = now() + C.IDLE_POLL
    st.stuck = {}
    if ctx.alert and ctx.alert.active("storage.intake") then ctx.alert.clear("storage.intake", "Склад: «Приёмка» разобрана") end
  elseif r.done and r.stuck > 0 and r.stuck >= r.items then
    st.next_t = now() + 10
    if ctx.alert and not ctx.alert.active("storage.intake") then
      ctx.alert.raise("storage.intake", "Склад: в «Приёмке» осталось то, что некуда разложить", { level = "warn", app = "storage" })
    end
  end
  if r.moved and r.moved > 0 and now() - S.last_start > 10 then S.soon = true end
end

-- «Разобрать сундук» — пока не разобран.
function Sort.job_step(ctx, B)
  local j = S.sort_job
  if not j then return end
  if not is_inv(j.src) then S.sort_job = nil; say_msg("Сундук для разбора пропал из сети.", colors.orange); return end
  local r = process_source(ctx, B, j.src, "sort", "store", nil, j.st)
  j.moved = j.moved + (r.moved or 0)
  if r.done and (r.empty or r.stuck >= r.items) then
    S.sort_job = nil
    S.soon = true
    say_msg("Разобран " .. Chest.title(ctx, j.src) .. ": перенесено " .. j.moved ..
      ((r.stuck or 0) > 0 and (", осталось видов: " .. r.stuck .. " (некуда)") or ""), colors.lime)
    return { moved = j.moved, left = r.stuck or 0 }
  end
end

-- Разобрать сразу (инструмент, КПК): до limit вызовов. -> { moved, left, done }
function Sort.now(ctx, src, limit)
  local st = { stuck = {} }
  local moved, last = 0, nil
  local B = { left = limit or 400 }
  for _ = 1, 50 do
    local r = process_source(ctx, B, src, "sort", "store", nil, st)
    moved = moved + (r.moved or 0)
    last = r
    if r.done or B.left <= 0 then break end
  end
  S.soon = true
  return { moved = moved, left = last and last.stuck or 0, done = last and last.done or false, empty = last and last.empty or false }
end

-- ---------- переплавка ----------
local Smelt = {}

-- Виды печей в сети: { name, kind, size, role }. Роль по размеру: 3 — всё, 2 — модем снизу (выход+топливо),
-- 1 — сверху (загрузка) или сбоку (топливо): узнаём пробой и запоминаем.
function Smelt.views(ctx, B)
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") then
      local kind = furnace_kind(n)
      if kind then
        local size = S.sizes[n]
        if size == nil and spend(B) then
          local ok, sz = pcall(peripheral.call, n, "size")
          size = ok and tonumber(sz) or 0
          S.sizes[n] = size
        end
        if size and size > 0 then
          local role = size >= 3 and "full" or (size == 2 and "bottom" or (ctx.data.fview[n] or "unknown"))
          out[#out + 1] = { name = n, kind = kind, size = size, role = role }
        end
      end
    end
  end
  return out
end

-- load — виды с загрузкой (вместе с ещё не проверенными: модем сверху или сбоку — узнаем при первой загрузке).
function Smelt.summary(views)
  local inn, outn, fuel, unk = 0, 0, 0, 0
  for _, v in ipairs(views) do
    local sl = SLOTS[v.role] or {}
    if sl.input then inn = inn + 1 end
    if sl.out then outn = outn + 1 end
    if sl.fuel then fuel = fuel + 1 end
    if v.role == "unknown" then unk = unk + 1 end
  end
  return { views = #views, load = inn + unk, out = outn, fuel = fuel, unknown = unk }
end

local function suits(kind, id)
  if kind == "blast" then return Spec.match({ kind = "cat", what = "руды" }, id, S.tags[id]) end
  if kind == "smoker" then
    local tags = S.tags[id]
    if tags then for t in pairs(tags) do if t:sub(1, 7) == "c:foods" then return true end end end
    for _, p in ipairs(FOOD_RAW) do if id:find(p) then return true end end
    return false
  end
  return true
end

function Smelt.find(task_key)
  for i, t in ipairs(S.tasks) do if t.key == task_key then return t, i end end
end

function Smelt.persist(ctx)
  local o = {}
  for _, t in ipairs(S.tasks) do
    if t.job then
      o[#o + 1] = { n = t.n, spec = t.spec, label = t.label, src = t.src, dest = t.dest, left = t.left, fed = t.fed,
        done = t.done, player = t.player }
    end
  end
  ctx.data.smelt = o
  ctx.save()
end

-- Новое задание. spec — что, src — "store" | сундук, dest — "store" | сундук | "me", left — сколько (nil — всё).
function Smelt.add(ctx, t, quiet)
  t.fed, t.done = t.fed or 0, t.done or 0
  t.state = "feed"
  t.started, t.last = now(), now()
  t.cur_ids = {}
  if t.flow then t.key = "f" .. t.flow
  else
    if not t.n then ctx.data.smelt_seq = (tonumber(ctx.data.smelt_seq) or 0) + 1; t.n = ctx.data.smelt_seq end
    t.key = "j" .. t.n
    t.job = true
  end
  S.tasks[#S.tasks + 1] = t
  if t.job and not quiet then Smelt.persist(ctx) end
  return t
end

local function smelt_alert(ctx, text_)
  if not ctx.alert then return end
  if text_ then
    if not ctx.alert.active("storage.smelt") then ctx.alert.raise("storage.smelt", text_, { level = "warn", app = "storage" }) end
  elseif ctx.alert.active("storage.smelt") then
    ctx.alert.clear("storage.smelt")
  end
end

function Smelt.finish(ctx, t, note)
  local _, i = Smelt.find(t.key)
  if i then table.remove(S.tasks, i) end
  S.drain, S.drain_step = true, nil
  if t.job then
    local s = "Переплавка: готово " .. t.done .. " (из «" .. t.label .. "», загружено " .. t.fed .. ")" ..
      (t.dest ~= "store" and (" → " .. t.dest_title) or "") .. (note and ("; " .. note) or "")
    S.smelt_note = s
    ctx.say(s, note and "warn" or "sys")
    Smelt.persist(ctx)
  else
    S.smelt_note = "Конвейер №" .. t.flow .. ": переплавлено " .. t.done .. (note and ("; " .. note) or "")
  end
  if #S.tasks == 0 then smelt_alert(ctx, nil) end
end

-- Кандидаты для загрузки задания со склада (по индексу).
local function store_cands(t)
  if t.cands and t.cands_pass == S.passes then return t.cands end
  local o = {}
  if S.index then
    for id, r in pairs(S.index.items) do
      if (r.chest + r.me) > 0 and not S.nosmelt[id] and not (t.spec.kind == "any") and Spec.match(t.spec, id, S.tags[id])
        and not FUEL_SET[id] then
        o[#o + 1] = { id = id, n = r.chest + r.me }
      end
      if Spec.needs_tags(t.spec) and not S.tags[id] and r.loc then S.need[id] = r.loc end
    end
  end
  table.sort(o, function(a, b) return a.n > b.n end)
  local ids = {}
  for i = 1, math.min(20, #o) do ids[i] = o[i].id end
  t.cands, t.cands_pass = ids, S.passes
  return ids
end

-- Загрузить вид печи v (слот slot, сейчас там cur, места room). -> moved, rejected
function Smelt.feed(ctx, B, t, v, slot, cur, room)
  local want = math.min(room, C.FEED)
  if t.left then want = math.min(want, t.left) end
  if want <= 0 then return 0 end
  local probe = v.role == "unknown"
  if t.src == "store" then
    for _, id in ipairs(store_cands(t)) do
      if (not cur or cur.name == id) and suits(v.kind, id) and not (probe and fuelish(id)) and have(id) > 0 then
        local moved, info = pull_from_store(ctx, B, id, want, v.name, slot)
        if moved > 0 then return Smelt.fed(t, moved, id), false, id end
        if info.err then t.warn = info.err end
        if info.stuck then return 0, true end
        if B and B.left <= 0 then return 0 end
      end
    end
    return 0
  end
  local list = t.src_list or {}
  for _, s in ipairs(sorted_keys(list)) do
    local it = list[s]
    if type(it) == "table" and it.count > 0 and (not cur or cur.name == it.name) and not S.nosmelt[it.name]
      and suits(v.kind, it.name) and not (probe and fuelish(it.name)) and Spec.match(t.spec, it.name, S.tags[it.name]) then
      local ok, n = call(B, t.src, "pushItems", v.name, s, math.min(want, it.count), slot)
      if not ok then
        if n ~= "budget" then t.warn = push_error(n) end
        return 0
      end
      n = math.floor(tonumber(n) or 0)
      if n > 0 then it.count = it.count - n; return Smelt.fed(t, n, it.name), false, it.name end
      return 0, true
    end
  end
  return 0
end

function Smelt.fed(t, n, id)
  t.fed = t.fed + n
  if t.left then t.left = t.left - n end
  t.last = now()
  t.cur_ids[id] = true
  return n
end

-- Топливо в слот вида печи (если мало).
function Smelt.refuel(ctx, B, v, slot, cur, t)
  local ids = {}
  if cur then ids[1] = cur.name else for _, f in ipairs(FUELS) do ids[#ids + 1] = f end end
  for _, id in ipairs(ids) do
    if not (t and t.cur_ids[id]) and have(id) > 0 then
      local want = (BLOCK_FUEL[id] or C.FUEL_FILL) - (cur and cur.count or 0)
      if want > 0 then
        local moved = pull_from_store(ctx, B, id, want, v.name, slot)
        if moved > 0 then return moved end
      end
    end
  end
  return 0
end

-- Вход печи не уменьшается: вернуть загруженное, печь отдыхает 5 минут.
function Smelt.stalled(ctx, B, v, slot, cur, t)
  local vs = S.vstate[v.name]
  local back = (t and t.src ~= "store") and t.src or "store"
  local moved = place(ctx, B, v.name, slot, cur, back)
  vs.stalled_until = now() + 300
  vs.in_t = now()
  local st = S.stall_ids[cur.name] or { n = 0, views = {}, distinct = 0 }
  S.stall_ids[cur.name] = st
  st.n = st.n + 1
  if not st.views[v.name] then st.views[v.name] = true; st.distinct = st.distinct + 1 end
  local loaders = Smelt.summary(S.views or {}).load
  if st.distinct >= 2 or (loaders <= 1 and st.n >= 2) then S.nosmelt[cur.name] = true end
  local s = Chest.title(ctx, v.name) .. " не плавит «" .. name_of(cur.name) .. "» — нет топлива (модем снизу печи) или это не плавится"
  if t then t.warn = s end
  return moved
end

-- Шаг переплавки (tick): собрать выход, подкинуть топливо, загрузить вход. Все виды за шаг, если хватает вызовов.
function Smelt.step(ctx, B)
  if #S.tasks == 0 and not S.drain then return end
  local views = Smelt.views(ctx, B)
  S.views = views
  local t = S.tasks[1]
  S.step_n = (S.step_n or 0) + 1
  if #views == 0 then
    if t then
      t.warn = "нет печей в сети"
      smelt_alert(ctx, "Склад: для переплавки нет печей в сети")
      if now() - t.last > C.SMELT_IDLE then Smelt.finish(ctx, t, t.warn) end
    end
    S.drain = false
    return
  end
  if t and t.state == "feed" and t.src ~= "store" then
    local ok, list = call(B, t.src, "list")
    t.src_list = (ok and type(list) == "table") and list or {}
    if Spec.needs_tags(t.spec) then
      for _, s in ipairs(sorted_keys(t.src_list)) do tags_for(B, t.src, s, t.src_list[s].name) end
    end
  end
  local visited, fuel_missing, loadable = 0, false, false
  for k = 0, #views - 1 do
    local v = views[((S.smelt_rr + k) % #views) + 1]
    if B and B.left <= 1 then break end
    local ok, list = call(B, v.name, "list")
    if ok and type(list) == "table" then
      visited = visited + 1
      local vs = S.vstate[v.name] or {}
      S.vstate[v.name] = vs
      vs.visit, vs.busy, vs.has_out = S.step_n, false, false
      if v.role == "unknown" and list[1] and not fuelish(list[1].name) then   -- топливный слот не держит руду
        ctx.data.fview[v.name] = "in"; v.role = "in"; S.dirty = true
      end
      local sl = SLOTS[v.role] or {}
      -- 1) выход
      if sl.out and list[sl.out] then
        local it = list[sl.out]
        local moved = place(ctx, B, v.name, sl.out, it, t and t.dest or "store")
        if t then t.done = t.done + moved; if moved > 0 then t.last = now() end end
        if moved < it.count then vs.has_out = true end
      end
      -- 2) вход
      local cur = sl.input and list[sl.input] or nil
      if sl.input then
        loadable = true
        if cur then
          vs.busy = true
          if vs.in_id ~= cur.name or vs.in_count ~= cur.count then
            if t and vs.in_id == cur.name and cur.count < (vs.in_count or 0) then t.last = now() end   -- плавится
            vs.in_id, vs.in_count, vs.in_t = cur.name, cur.count, now()
          elseif now() - (vs.in_t or now()) > C.STALL and (not vs.stalled_until or now() > vs.stalled_until) then
            Smelt.stalled(ctx, B, v, sl.input, cur, t)
            cur = nil
          end
        end
        if t and t.state == "feed" and (not vs.stalled_until or now() > vs.stalled_until) and (not cur or cur.count <= 64 - 8) then
          local moved, _, id = Smelt.feed(ctx, B, t, v, sl.input, cur, cur and (64 - cur.count) or 64)
          if moved > 0 then
            vs.busy = true
            vs.in_id, vs.in_count, vs.in_t = id, (cur and cur.count or 0) + moved, now()
          end
        end
      elseif v.role == "unknown" and t and t.state == "feed" and not list[1] then
        local moved, rejected = Smelt.feed(ctx, B, t, v, 1, nil, C.FEED)
        if moved > 0 then ctx.data.fview[v.name] = "in"; S.dirty = true; vs.busy = true; loadable = true
        elseif rejected then ctx.data.fview[v.name] = "fuel"; S.dirty = true end
      end
      -- 3) топливо
      if sl.fuel and t then
        local f = list[sl.fuel]
        local low = not f or f.count < (BLOCK_FUEL[f.name] and 2 or C.FUEL_LOW)
        if low and Smelt.refuel(ctx, B, v, sl.fuel, f, t) == 0 and not f then fuel_missing = true end
      end
    end
  end
  S.smelt_rr = S.smelt_rr + visited
  -- все виды проверены после начала «доплавки» (за один или несколько шагов) и пусты?
  local function drained(since)
    for _, v in ipairs(views) do
      local vs = S.vstate[v.name]
      if not vs or (vs.visit or 0) <= since or vs.busy or vs.has_out then return false end
    end
    return true
  end
  if not t then
    S.drain_step = S.drain_step or S.step_n - 1
    if drained(S.drain_step) then S.drain, S.drain_step = false, nil end
    return
  end
  -- предупреждения
  if not loadable and visited > 0 then
    t.warn = "у печей нет загрузки: поставьте проводной модем СВЕРХУ печи"
  elseif fuel_missing then
    t.warn = "нет топлива на складе (уголь, древесный уголь)"
  elseif t.warn and t.warn:find("не плавит", 1, true) == nil then
    t.warn = nil
  end
  smelt_alert(ctx, t.warn and ("Склад: переплавка — " .. t.warn) or nil)
  -- закончилась загрузка?
  if t.state == "feed" then
    local more
    if t.left and t.left <= 0 then more = false
    elseif t.src == "store" then
      more = false
      for _, id in ipairs(store_cands(t)) do if have(id) > 0 then more = true; break end end
    else
      more = false
      for _, s in ipairs(sorted_keys(t.src_list or {})) do
        local it = t.src_list[s]
        if it.count > 0 and not S.nosmelt[it.name] and Spec.match(t.spec, it.name, S.tags[it.name]) then more = true; break end
      end
    end
    if not more then t.state = "drain"; t.drain_step = S.step_n end
  end
  if t.state == "drain" and drained(t.drain_step) then
    Smelt.finish(ctx, t)
  elseif now() - t.last > C.SMELT_IDLE then
    Smelt.finish(ctx, t, t.warn or "печи давно стоят")
  end
end

-- Остановить: задание n (или все разовые). Загруженное в печи вернуть (вход сверху) на склад.
function Smelt.stop(ctx, n)
  local stopped = 0
  local head = S.tasks[1]
  local pull = head ~= nil and head.job and (not n or head.n == n)
  for i = #S.tasks, 1, -1 do
    local t = S.tasks[i]
    if t.job and (not n or t.n == n) then table.remove(S.tasks, i); stopped = stopped + 1 end
  end
  Smelt.persist(ctx)
  local back = 0
  for _, v in ipairs(pull and Smelt.views(ctx, nil) or {}) do
    local sl = SLOTS[v.role] or {}
    if sl.input then
      local ok, list = pcall(peripheral.call, v.name, "list")
      local cur = ok and type(list) == "table" and list[sl.input]
      if cur then back = back + place(ctx, nil, v.name, sl.input, cur, "store") end
    end
  end
  S.drain, S.drain_step = true, nil
  if #S.tasks == 0 then smelt_alert(ctx, nil) end
  return stopped, back
end

-- Разовое задание: что (текст), сколько (0/nil — всё). -> задание | nil, ошибка
function Smelt.request(ctx, what, count, player)
  ensure_index(ctx)
  local sp, err = Spec.parse(what)
  if not sp then return nil, err end
  if sp.kind == "any" then return nil, "что переплавить? Например: руды, песок, железная руда" end
  local views = Smelt.views(ctx, nil)
  if #views == 0 then
    return nil, "в сети нет печей: поставьте печь и проводной модем сверху (загрузка) и снизу (выход и топливо)"
  end
  count = math.floor(tonumber(count) or 0)
  local t = { spec = sp, label = Spec.label(sp), src = "store", dest = "store", left = count > 0 and count or nil,
    player = nick(player) }
  local avail = 0
  for _, id in ipairs(store_cands(t)) do avail = avail + have(id) end
  if avail == 0 then return nil, "на складе нет «" .. t.label .. "»" end
  Smelt.add(ctx, t)
  return t, nil, Smelt.summary(views), avail
end

function Smelt.status(ctx)
  local sum = Smelt.summary(S.views or {})
  local tasks = {}
  for i, t in ipairs(S.tasks) do
    tasks[#tasks + 1] = { n = t.n, flow = t.flow, what = t.label, active = i == 1, state = t.state,
      fed = t.fed, done = t.done, left = t.left, warn = t.warn,
      from = Chest.title(ctx, t.src), to = t.dest_title or Chest.title(ctx, t.dest) }
  end
  local fv = {}
  for _, v in ipairs(S.views or {}) do
    fv[#fv + 1] = { furnace = Chest.title(ctx, v.name), kind = FURN_LABEL[v.kind], modem = VIEW_LABEL[v.role] }
  end
  return { furnaces = fv, load = sum.load, out = sum.out, fuel = sum.fuel, tasks = tasks, last = S.smelt_note }
end

-- ---------- конвейеры ----------
local Flow = {}

local function flow_title(ctx, f)
  return "№" .. f.n .. " " .. Chest.ref(ctx, f.from) .. " → " .. ACTION_WORD[f.action] ..
    (f.filter and (" (" .. Spec.label(f.filter) .. ")") or "") ..
    ((f.action == "move" or f.action == "smelt") and (" → " .. Chest.ref(ctx, f.to)) or "")
end

-- -> конвейер | nil, ошибка, варианты
function Flow.add(ctx, from_q, action_q, to_q, filter_q)
  local from, err, opts = Chest.which(ctx, from_q)
  if not from then return nil, "откуда: " .. err, opts end
  local r = role_of(ctx, from)
  if r == "memory" or r == "issue" or r == "intake" or r == "furnace" then
    return nil, "из " .. Chest.title(ctx, from) .. " конвейер не сделать (" .. ROLE_LABEL[r] .. ")"
  end
  local action = ACTIONS[norm(action_q)]
  if not action then return nil, "что делать: переплавить, переложить, разложить или в МЭ" end
  local to = "store"
  if action == "me" then to = "me"
  elseif action ~= "sort" and u8.trim(tostring(to_q or "")) ~= "" then
    local e2, o2
    to, e2, o2 = Chest.which(ctx, to_q, { me = true, store = true })
    if not to then return nil, "куда: " .. e2, o2 end
    if to ~= "store" and to ~= "me" and not valid_target(ctx, to) and role_of(ctx, to) ~= "flow" then
      return nil, "туда класть нельзя: " .. Chest.title(ctx, to)
    end
  elseif action == "move" then
    return nil, "куда переложить?"
  end
  if to == from then return nil, "откуда и куда — один и тот же сундук" end
  local filter
  if u8.trim(tostring(filter_q or "")) ~= "" then
    local e3
    filter, e3 = Spec.parse(filter_q)
    if not filter then return nil, "фильтр: " .. e3 end
    if filter.kind == "any" then filter = nil end
  end
  if #ctx.data.flows >= C.MAX_FLOWS then return nil, "конвейеров уже " .. C.MAX_FLOWS end
  ctx.data.flow_seq = (tonumber(ctx.data.flow_seq) or 0) + 1
  local f = { n = ctx.data.flow_seq, from = from, action = action, to = to, filter = filter }
  ctx.data.flows[#ctx.data.flows + 1] = f
  ctx.save()
  S.soon = true
  return f
end

function Flow.remove(ctx, n)
  for i, f in ipairs(ctx.data.flows) do
    if f.n == n then
      table.remove(ctx.data.flows, i)
      local t = Smelt.find("f" .. n)
      if t then Smelt.finish(ctx, t, "конвейер удалён") end
      if ctx.alert and ctx.alert.active("storage.flow." .. n) then ctx.alert.clear("storage.flow." .. n) end
      ctx.save()
      S.soon = true
      return f
    end
  end
end

-- Разбор конвейеров текстом «откуда > действие > куда [> что]».
function Flow.parse_add(ctx, s)
  local parts = {}
  local str = tostring(s or ""):gsub("%->", ">")
  for p in (str .. ">"):gmatch("(.-)>") do parts[#parts + 1] = u8.trim(p) end
  if #parts == 2 then
    local a = ACTIONS[norm(parts[2])]
    if a == "sort" or a == "me" then return Flow.add(ctx, parts[1], parts[2]) end
    return Flow.add(ctx, parts[1], "переложить", parts[2])
  end
  if #parts < 3 then return nil, "формат: откуда > действие > куда (например: руды > переплавить > из печи)" end
  return Flow.add(ctx, parts[1], parts[2], parts[3], parts[4])
end

function Flow.describe(ctx, f)
  local st = S.fstate[f.n] or {}
  return { n = f.n, from = Chest.title(ctx, f.from), action = ACTION_WORD[f.action], to = Chest.title(ctx, f.to),
    filter = f.filter and Spec.label(f.filter) or nil, status = st.status or "ждёт" }
end

function Flow.step(ctx, B)
  local flows = ctx.data.flows
  for _, f in ipairs(flows) do
    if B and B.left <= 1 then break end
    local st = S.fstate[f.n] or { stuck = {}, next_t = 0 }
    S.fstate[f.n] = st
    if now() >= st.next_t then
      if not is_inv(f.from) then
        st.status, st.next_t = "нет сундука " .. Chest.ref(ctx, f.from), now() + 10
      elseif f.action == "smelt" then
        if Smelt.find("f" .. f.n) then
          st.status = "плавит"
        else
          local ok, list = call(B, f.from, "list")
          local any = false
          if ok and type(list) == "table" then
            for _, s in ipairs(sorted_keys(list)) do
              local it = list[s]
              local tags = (f.filter and Spec.needs_tags(f.filter)) and tags_for(B, f.from, s, it.name) or S.tags[it.name]
              if not S.nosmelt[it.name] and Spec.match(f.filter, it.name, tags) then any = true; break end
            end
          end
          if any then
            Smelt.add(ctx, { flow = f.n, spec = f.filter or { kind = "any" },
              label = "конвейер №" .. f.n .. (f.filter and (" (" .. Spec.label(f.filter) .. ")") or ""),
              src = f.from, dest = f.to, dest_title = Chest.title(ctx, f.to) })
            st.status = #S.tasks > 1 and "в очереди печей" or "плавит"
          else
            st.status, st.next_t = "ждёт", now() + C.IDLE_POLL
          end
        end
      else
        local r = process_source(ctx, B, f.from, f.action, f.to, f.filter, st)
        local key = "storage.flow." .. f.n
        if r.budget then
          break
        elseif r.err and not r.items then
          st.status = r.err
        elseif r.empty or (r.items or 0) == 0 then
          st.status, st.next_t = "ждёт", now() + C.IDLE_POLL
          if ctx.alert and ctx.alert.active(key) then ctx.alert.clear(key) end
        elseif r.done and r.stuck > 0 and r.stuck >= r.items then
          st.status, st.next_t = "некуда класть", now() + 10
          if ctx.alert and not ctx.alert.active(key) then
            ctx.alert.raise(key, "Склад: конвейер №" .. f.n .. " — из " .. Chest.ref(ctx, f.from) .. " некуда переложить",
              { level = "warn", app = "storage" })
          end
        else
          st.status = "работает"
        end
      end
    end
  end
end

-- ---------- описание предмета ----------
local function describe(ctx, id)
  local r = S.index and S.index.items[id] or { chest = 0, me = 0, where = {} }
  local parts = {}
  if r.me > 0 then parts[#parts + 1] = "МЭ " .. r.me end
  local w = {}
  for inv, n in pairs(r.where) do w[#w + 1] = { inv = inv, n = n } end
  table.sort(w, function(a, b) return a.n > b.n end)
  for i = 1, math.min(4, #w) do parts[#parts + 1] = Chest.ref(ctx, w[i].inv) .. " " .. w[i].n end
  if #w > 4 then parts[#parts + 1] = "ещё сундуков: " .. (#w - 4) end
  return { id = id, name = name_of(id), total = r.chest + r.me, in_chests = r.chest, in_me = r.me,
    where = table.concat(parts, "; "), craftable = r.craftable or nil }
end

-- ---------- экран ----------
local function where_short(r)
  if r.me > 0 and r.chest > 0 then return "МЭ+сунд." end
  if r.me > 0 then return "МЭ" end
  if r.chest > 0 then return "сунд." end
  return "нет"
end

local function result_row(ctx, id)
  local r = S.index and S.index.items[id] or { chest = 0, me = 0, where = {} }
  local total = r.chest + r.me
  local d = describe(ctx, id)
  local def = math.max(1, math.min(64, total))
  return { text = name_of(id), value = fmt(total) .. " · " .. where_short(r), fg = total > 0 and colors.white or colors.gray,
    prompt = { label = "Выдать «" .. text.sub(name_of(id), 1, 16) .. "», шт", op = "take", id = id, max = 6,
      placeholder = "пусто — " .. def .. ", «все» — " .. total },
    del = { op = "watch_quick", id = id, label = "следить" },
    hint = "Enter — выдать · Delete — следить (не меньше 64)",
    desc = (d.where ~= "" and d.where or "нет на складе") .. (r.craftable and " · МЭ крафтит" or "") .. " · " .. id }
end

local function summary()
  local ix = S.index
  if not ix then return S.pass and "считаю…" or "нет данных" end
  local parts = { fmt(ix.total) .. " шт." }
  if ix.n_invs > 0 then
    local p = pct(ix.slots_used, ix.slots_total)
    parts[#parts + 1] = "сундуков " .. ix.n_invs .. (p and (", занято " .. p .. "%") or "")
  end
  if ix.me_on then
    local p = pct(ix.me_used, ix.me_max)
    parts[#parts + 1] = "МЭ" .. (p and (" " .. p .. "%") or "")
  end
  return table.concat(parts, " · ")
end

local PICK_TITLE = { issue = "Выберите сундук «Выдача»", intake = "Выберите сундук «Приёмка»",
  misc = "Выберите сундук «Разное»", sort = "Какой сундук разобрать?" }

local function rows_pick(ctx)
  local mode = S.pick
  local out = { { text = PICK_TITLE[mode] or "Выберите сундук", header = true } }
  local n = 0
  local cur = mode ~= "sort" and ctx.data[mode] or nil
  for _, c in ipairs(classify(ctx)) do
    local skip = c.role == "core" or c.role == "memory" or c.role == "bridge" or c.role == "furnace"
      or (mode == "sort" and (c.role == "issue" or c.role == "intake"))
      or ((mode == "intake" or mode == "misc") and c.role == "issue")
      or ((mode == "issue" or mode == "misc") and c.role == "intake")
    if not skip then
      n = n + 1
      out[#out + 1] = { text = Chest.title(ctx, c.name), value = c.name == cur and "сейчас" or (c.side and "вплотную" or ROLE_LABEL[c.role]),
        fg = c.name == cur and colors.lime or colors.white,
        action = { op = "pick_set", mode = mode, name = c.name, label = "выбрать" },
        desc = c.side and "Вплотную к компьютеру: сундуки сети и МЭ сюда не дотянутся — лучше сундук на модеме."
          or (c.name .. (Chest.top(c.name) ~= "" and (" · " .. Chest.top(c.name)) or "")) }
    end
  end
  if n == 0 then out[#out + 1] = { text = "нет подходящих сундуков в сети", fg = colors.orange } end
  if mode == "intake" or mode == "misc" then
    out[#out + 1] = { text = "— не нужен", fg = colors.lightGray, action = { op = "pick_set", mode = mode, name = "", label = "убрать" } }
  end
  out[#out + 1] = { text = "← назад", fg = colors.lightGray, action = { op = "pick_cancel", label = "назад" } }
  return out
end

-- Сообщение — всегда ровно две строки (число строк над списком не меняется, выбор не прыгает).
local function msg_rows(out, w)
  local s, fg = "Найдите предмет: Enter на нём — выдать в «Выдачу», Delete — следить за запасом.", colors.gray
  if S.msg then s, fg = S.msg.text, S.msg.fg or colors.white end
  local width = math.max(10, (w or 51) - 2)
  local lines = text.wrap(s, width)
  for i = 1, 2 do
    local l = lines[i] or ""
    if i == 2 and lines[3] then l = text.sub(l, 1, width - 3) .. "..." end
    out[#out + 1] = { text = l, fg = fg }
  end
end

local HELP_RULES = [[Правило: что > куда. Предметы из «Приёмки» (и при «Разобрать сундук») раскладываются так:
1) по правилу; 2) в сундук, где этот предмет уже лежит; 3) в МЭ, если «Лишнее — в МЭ»; 4) в «Разное».
Не вышло — остаётся в «Приёмке», тревога.

ЧТО:
- название или ID предмета: железный слиток, minecraft:iron_ingot;
- мод: create:  (или «мод create»);
- тег: #c:ingots, #minecraft:logs;
- категория: руды, слитки, самоцветы, пыль, блоки ресурсов, еда, семена, урожай, саженцы, дерево, камень, песок,
  блоки, инструменты, оружие, броня, зелья, красители, с мобов.
Если подходят несколько правил: точный предмет важнее тега, тег — категории, категория — мода.

КУДА: имя сундука (дайте его в «Источниках»), номер (№7) или МЭ.
Примеры: слитки > №5 · руды > руды · create: > МЭ · minecraft:cobblestone > камень]]

local HELP_FLOWS = [[Конвейер работает всё время: появилось в сундуке «откуда» — ЛОЦМАН обрабатывает порциями.
Запись: откуда > действие > куда [> что].
Действия: переплавить (в печах сети, результат — в «куда»), переложить, разложить (по правилам склада), в МЭ.
Куда: имя или номер сундука, «склад» или МЭ. Что (необязательно): категория, тег, мод или предмет.
Примеры:
  руды > переплавить > из печи
  ферма > переложить > склад
  добыча > разложить
  шахта > в МЭ > руды
Сундуки конвейеров не считаются складом — «Выдача» их не трогает.]]

local HELP_SMELT = [[Переплавка — в обычных печах, плавильных печах (руда) и коптильнях (еда) в проводной сети.
Модем на печи видит только свою грань: СВЕРХУ — загрузка, СНИЗУ — выход и топливо, СБОКУ — только топливо.
Нужны оба модема (сверху и снизу) — тогда ЛОЦМАН загрузит, подкинет уголь со склада и заберёт готовое.
Задание: «руды все», «песок 64», «железная руда 32». Результат — на склад (по правилам и «где уже лежит»).
Электропечи Mekanism не загружаются (у них своя периферия без переноса предметов).]]

local function rows_term(ctx, w)
  if S.pick then return rows_pick(ctx) end
  local d = ctx.data
  local out = {}
  out[#out + 1] = { text = "Склад: " .. summary(), header = true }
  msg_rows(out, w)
  out[#out + 1] = { text = "Найти…", value = S.query ~= "" and ("«" .. S.query .. "»") or nil, fg = colors.yellow,
    prompt = { label = "Найти", op = "find", value = S.query, max = 40, placeholder = "название или ID; пусто — сброс" },
    hint = "Enter — искать по названию или ID",
    desc = "Ищет в сундуках сети и в МЭ: «железо», «алмаз», ID." }
  -- предложение автокрафта — сразу под предметом (строки выше не сдвигаются)
  local offer_row = S.offer and { text = "Заказать в МЭ: «" .. name_of(S.offer.id) .. "» ×" .. S.offer.count, fg = colors.yellow,
    action = { op = "craft", id = S.offer.id, count = S.offer.count, label = "заказать автокрафт" },
    del = { op = "offer_cancel", label = "не надо" },
    hint = "Enter — заказать автокрафт · Delete — не надо",
    desc = "Крупный заказ подтверждают в чате: «да КОД»." }
  if S.query ~= "" then
    if #S.results == 0 then
      out[#out + 1] = { text = S.index and "ничего не нашлось" or "склад ещё считается…", fg = colors.gray }
    else
      for _, id in ipairs(S.results) do
        out[#out + 1] = result_row(ctx, id)
        if offer_row and S.offer.id == id then out[#out + 1] = offer_row; offer_row = nil end
      end
    end
  end
  if offer_row then out[#out + 1] = offer_row end
  -- наблюдение
  out[#out + 1] = { text = "Наблюдение", header = true }
  for _, wch in ipairs(d.watch or {}) do
    local h = have(wch.id)
    out[#out + 1] = { text = watch_name(wch), value = fmt(h) .. "/" .. fmt(wch.min),
      fg = (S.index and h < wch.min) and colors.red or colors.white,
      prompt = { label = "Минимум", op = "watch_set", id = wch.id, value = tostring(wch.min), max = 8 },
      del = { op = "watch_del", id = wch.id, label = "не следить" },
      hint = "Enter — изменить минимум · Delete — не следить",
      desc = "Тревога, когда меньше " .. wch.min .. " · " .. wch.id }
  end
  out[#out + 1] = { text = "+ следить за предметом…", fg = colors.lightGray,
    prompt = { label = "Что и минимум", op = "watch_new", max = 50, placeholder = "железный слиток 64" },
    hint = "Enter — добавить: название и минимум",
    desc = "Тревога на «Главной» и КПК, когда на складе меньше минимума." }
  -- выдача
  out[#out + 1] = { text = "Выдача", header = true }
  local issue = d.issue
  local ok_issue = is_inv(issue)
  out[#out + 1] = { text = "Сундук «Выдача»",
    value = issue and (ok_issue and Chest.title(ctx, issue) or (issue .. " — нет")) or "не выбран",
    fg = ok_issue and colors.white or colors.orange,
    action = { op = "pick", mode = "issue", label = "выбрать сундук" },
    desc = "Сюда кладутся выданные предметы. Он, склад и МЭ-мост — в одной проводной сети." }
  -- сортировка
  out[#out + 1] = { text = "Сортировка", header = true }
  local ii = S.intake_info
  out[#out + 1] = { text = "Сундук «Приёмка»", value = d.intake and (is_inv(d.intake) and Chest.title(ctx, d.intake) or "нет в сети") or "не выбран",
    fg = (d.intake and not is_inv(d.intake)) and colors.orange or colors.white,
    action = { op = "pick", mode = "intake", label = "выбрать сундук" },
    desc = not d.intake and "Всё, что положите в «Приёмку», ЛОЦМАН разложит сам."
      or (ii and (ii.empty and "Приёмка пуста." or ("В приёмке видов: " .. (ii.items or 0) .. ", некуда: " .. (ii.stuck or 0)))
      or "Разбирается порциями.") }
  out[#out + 1] = { text = "Сундук «Разное»", value = d.misc and (is_inv(d.misc) and Chest.title(ctx, d.misc) or "нет в сети") or "нет",
    action = { op = "pick", mode = "misc", label = "выбрать сундук" },
    desc = "Сюда — то, чему не нашлось места по правилам, рядом с такими же и в МЭ." }
  out[#out + 1] = { text = "Лишнее — в МЭ", value = d.overflow_me ~= false and "да" or "нет",
    action = { op = "overflow", label = d.overflow_me ~= false and "не класть лишнее в МЭ" or "класть лишнее в МЭ" },
    desc = "Без правила и без места рядом с такими же — в МЭ-сеть." }
  for _, r in ipairs(d.rules or {}) do
    out[#out + 1] = { text = Spec.label(r), value = "→ " .. Chest.ref(ctx, r.to),
      fg = (r.to == "me" or is_inv(r.to)) and colors.white or colors.orange,
      prompt = { label = "Правило", op = "rule_set", n = r.n, value = Sort.text(ctx, r), max = 60 },
      del = { op = "rule_del", n = r.n, label = "удалить" },
      hint = "Enter — изменить · Delete — удалить",
      desc = Sort.text(ctx, r) .. " · " .. (r.kind == "cat" and "категория" or (r.kind == "tag" and "тег" or (r.kind == "mod" and "мод" or "предмет"))) }
  end
  out[#out + 1] = { text = "+ правило…", fg = colors.lightGray,
    prompt = { label = "Что > куда", op = "rule_add", max = 60, placeholder = "слитки > №5" },
    hint = "Enter — добавить правило «что > куда»",
    desc = "Что: предмет, мод (create:), тег (#c:ingots), категория (руды…). Куда: имя, №, МЭ." }
  out[#out + 1] = { text = "Как писать правила", fg = colors.lightGray, read = { title = "Правила сортировки", body = HELP_RULES },
    hint = "Enter — прочитать", desc = "Категории, теги, примеры." }
  out[#out + 1] = { text = "Разобрать сундук…", fg = colors.lightGray, action = { op = "pick", mode = "sort", label = "выбрать сундук" },
    value = S.sort_job and ("идёт: " .. Chest.ref(ctx, S.sort_job.src)) or nil,
    desc = "Разложить содержимое сундука по тем же правилам." }
  -- переплавка
  out[#out + 1] = { text = "Переплавка", header = true }
  local sum = Smelt.summary(S.views or {})
  out[#out + 1] = { text = "Печи", value = sum.views == 0 and "нет" or ("загрузка " .. sum.load .. ", выход " .. sum.out),
    fg = sum.views == 0 and colors.gray or colors.white,
    read = { title = "Переплавка", body = HELP_SMELT .. "\n\nВиды печей:\n" .. (function()
      local o = {}
      for _, v in ipairs(S.views or {}) do o[#o + 1] = "- " .. Chest.title(ctx, v.name) .. ": " .. FURN_LABEL[v.kind] .. ", модем — " .. VIEW_LABEL[v.role] end
      return #o > 0 and table.concat(o, "\n") or "(печей не видно — они появятся, когда будет задание)"
    end)() },
    hint = "Enter — как подключить печи", desc = "Модем сверху печи — загрузка, снизу — выход и топливо." }
  for i, t in ipairs(S.tasks) do
    out[#out + 1] = { text = t.label .. (t.left and (" ещё " .. t.left) or ""),
      value = (i == 1 and (t.state == "drain" and "доплавляю" or "плавлю") or "в очереди") .. " · " .. t.done,
      fg = t.warn and colors.orange or colors.white,
      del = t.job and { op = "smelt_stop", n = t.n, label = "остановить" } or nil,
      row = { kind = "smelt" },
      hint = t.job and "Delete — остановить" or "Конвейер: удалить — в разделе «Конвейеры»",
      desc = t.warn or ("загружено " .. t.fed .. ", готово " .. t.done .. " → " .. (t.dest_title or Chest.title(ctx, t.dest))) }
  end
  if S.smelt_note then out[#out + 1] = { text = S.smelt_note, fg = colors.lightGray } end
  out[#out + 1] = { text = "+ переплавить…", fg = colors.lightGray,
    prompt = { label = "Что и сколько", op = "smelt_add", max = 50, placeholder = "руды все / песок 64" },
    hint = "Enter — задание на переплавку", desc = "Со склада в печи сети; готовое — обратно на склад." }
  -- конвейеры
  out[#out + 1] = { text = "Конвейеры", header = true }
  for _, f in ipairs(d.flows or {}) do
    local st = S.fstate[f.n] or {}
    out[#out + 1] = { text = flow_title(ctx, f), value = st.status or "ждёт",
      fg = (st.status == "некуда класть" or (st.status or ""):find("нет", 1, true)) and colors.orange or colors.white,
      del = { op = "flow_del", n = f.n, label = "удалить" }, row = { kind = "flow" },
      hint = "Delete — удалить конвейер",
      desc = Chest.title(ctx, f.from) .. " → " .. ACTION_WORD[f.action] .. " → " .. Chest.title(ctx, f.to) }
  end
  out[#out + 1] = { text = "+ конвейер…", fg = colors.lightGray,
    prompt = { label = "Откуда > что делать > куда", op = "flow_add", max = 70, placeholder = "руды > переплавить > из печи" },
    hint = "Enter — добавить конвейер", desc = "Действия: переплавить, переложить, разложить, в МЭ." }
  out[#out + 1] = { text = "Как устроены конвейеры", fg = colors.lightGray, read = { title = "Конвейеры", body = HELP_FLOWS },
    hint = "Enter — прочитать", desc = "Запись и примеры." }
  -- источники
  out[#out + 1] = { text = "Источники", header = true }
  local me_val
  if not ctx.me or not has_bridge() then me_val = "нет моста"
  elseif d.use_me == false then me_val = "не учитывается"
  elseif S.index and S.index.me_on then
    local p = pct(S.index.me_used, S.index.me_max)
    me_val = "в сети" .. (p and (" · " .. p .. "%") or "")
  elseif S.index then me_val = "не отвечает"
  else me_val = "проверяю…" end
  out[#out + 1] = { text = "МЭ-сеть", value = me_val, fg = colors.white,
    action = { op = "me", label = d.use_me == false and "учитывать МЭ" or "не учитывать МЭ" },
    desc = "ME Bridge в сети компьютера: запасы МЭ, выдача и автокрафт." }
  local chosen = d.mode == "chosen"
  out[#out + 1] = { text = "Какие инвентари — склад", value = chosen and "только отмеченные" or "все, кроме исключённых",
    action = { op = "mode", label = chosen and "все, кроме исключённых" or "только отмеченные" },
    desc = "Ниже — каждый инвентарь: Enter — назвать, Delete — включить в склад или исключить." }
  local list = classify(ctx)
  for _, c in ipairs(list) do
    local st = S.index and S.index.invs[c.name]
    local val = ROLE_LABEL[c.role] or c.role
    if c.role == "store" and st and st.size > 0 then val = val .. " " .. st.used .. "/" .. st.size end
    if c.name == d.misc then val = "Разное · " .. val end
    local seen = tonumber(d.seen[c.name]) or 0
    local fresh = seen > 0 and now() - seen < C.NEW_WINDOW
    local row = { text = Chest.title(ctx, c.name) .. (fresh and " (новый)" or ""), value = val,
      fg = c.role == "store" and colors.white or colors.gray,
      prompt = { label = "Имя для " .. (d.nums[c.name] and ("№" .. d.nums[c.name]) or "сундука"), op = "rename", name = c.name,
        value = d.labels[c.name] or "", max = 24, placeholder = "например: руды; пусто — без имени" } }
    if c.hard then
      row.hint = "Enter — назвать"
      row.desc = c.name .. " · " .. (ROLE_DESC[c.role] or "")
    else
      local on = c.role == "store"
      row.del = { op = "inv", name = c.name, on = not on, label = on and "исключить из склада" or "считать складом" }
      row.hint = "Enter — назвать · Delete — " .. (on and "исключить из склада" or "считать складом")
      row.desc = c.name .. " · " .. (c.role == "machine" and "похоже на машину — по умолчанию не склад"
        or (Chest.top(c.name) ~= "" and Chest.top(c.name) or (on and "входит в склад" or "не входит в склад")))
    end
    out[#out + 1] = row
  end
  if #list == 0 then
    out[#out + 1] = { text = "нет сундуков: подключите их проводными модемами", fg = colors.orange }
  end
  return out
end

-- Монитор (узкая правая половина): заполненность, что заканчивается, приёмка и печи.
local function rows_mon(ctx)
  local out = {}
  local ix = S.index
  if not ix then
    out[#out + 1] = { text = S.pass and "считаю склад…" or "нет данных", fg = colors.gray }
  else
    out[#out + 1] = { text = "Всего " .. fmt(ix.total) .. " шт." }
    if ix.n_invs > 0 then
      local p = pct(ix.slots_used, ix.slots_total)
      out[#out + 1] = { text = "Сундуки " .. (p and (p .. "%") or "?") .. " (" .. ix.n_invs .. ")",
        fg = (p and p >= 90) and colors.orange or colors.white }
    end
    if ix.me_on then
      local p = pct(ix.me_used, ix.me_max)
      out[#out + 1] = { text = "МЭ " .. (p and (p .. "%") or "в сети"), fg = (p and p >= 90) and colors.orange or colors.white }
    end
    if ix.n_invs == 0 and not ix.me_on then out[#out + 1] = { text = "нет сундуков", fg = colors.orange } end
  end
  if S.intake_info and not S.intake_info.empty and (S.intake_info.stuck or 0) > 0 then
    out[#out + 1] = { text = "Приёмка: некуда " .. S.intake_info.stuck, fg = colors.orange }
  end
  if #S.tasks > 0 then
    local t = S.tasks[1]
    out[#out + 1] = { text = "Плавка: " .. t.label .. " " .. t.done, fg = t.warn and colors.orange or colors.white }
  end
  if #S.low > 0 then
    out[#out + 1] = { text = "Мало", header = true }
    for _, l in ipairs(S.low) do
      out[#out + 1] = { text = name_of(l.id, l.name) .. " " .. fmt(l.have) .. "/" .. fmt(l.min), fg = colors.red }
    end
  elseif #(ctx.data.watch or {}) > 0 and ix then
    out[#out + 1] = { text = "запасы в норме", fg = colors.lime }
  end
  return out
end

-- ---------- договор приложения ----------
function A.init(ctx)
  reset_state()
  local d = ctx.data
  local watch = {}
  for _, w in ipairs(type(d.watch) == "table" and d.watch or {}) do
    if type(w) == "table" and valid_id(w.id) and tonumber(w.min) and tonumber(w.min) > 0 then
      watch[#watch + 1] = { id = w.id, min = math.floor(tonumber(w.min)), name = type(w.name) == "string" and w.name or nil }
    end
  end
  d.watch = watch
  for _, k in ipairs({ "inv", "labels", "nums", "seen", "fview" }) do
    if type(d[k]) ~= "table" then d[k] = {} end
  end
  for _, k in ipairs({ "rules", "flows", "smelt" }) do
    if type(d[k]) ~= "table" then d[k] = {} end
  end
  local rules = {}
  for _, r in ipairs(d.rules) do
    if type(r) == "table" and KIND_RANK[r.kind] and type(r.what) == "string" and type(r.to) == "string" then rules[#rules + 1] = r end
  end
  d.rules = rules
  local flows = {}
  for _, f in ipairs(d.flows) do
    if type(f) == "table" and type(f.from) == "string" and ACTION_WORD[f.action] and type(f.to) == "string" then flows[#flows + 1] = f end
  end
  d.flows = flows
  local names = util.load_json(C.NAMES_PATH, {})
  if type(names) == "table" then
    for k, v in pairs(names) do if type(k) == "string" and type(v) == "string" then S.names[k] = v end end
  end
  for _, j in ipairs(d.smelt) do
    if type(j) == "table" and type(j.spec) == "table" and type(j.label) == "string" then
      Smelt.add(ctx, { n = j.n, spec = j.spec, label = j.label, src = j.src or "store", dest = j.dest or "store",
        left = tonumber(j.left), fed = tonumber(j.fed) or 0, done = tonumber(j.done) or 0, player = j.player }, true)
    end
  end
end

function A.tick(ctx)
  Chest.sync(ctx)
  local used = 0
  if S.pass or S.soon or now() - S.last_start >= C.RESCAN then used = scan_step(ctx, C.LIST_PER_TICK) or 0 end
  detail_step(C.DETAIL_PER_TICK)
  local B = { left = math.max(4, C.TICK_CALLS - used) }
  S.tickn = S.tickn + 1
  local steps = { Sort.intake_step, Sort.job_step, Flow.step, Smelt.step }
  for k = 0, #steps - 1 do
    local f = steps[((S.tickn + k) % #steps) + 1]
    if B.left > 0 then f(ctx, B) end
  end
  if S.dirty then S.dirty = false; ctx.save() end
end

function A.event(ctx, name, a)
  if name == "peripheral" then Chest.attached(ctx, a); S.soon = true
  elseif name == "peripheral_detach" then S.soon = true end
end

-- Терминал — полный список; монитор — сводка.
function A.rows(ctx, w, where)
  if where == "monitor" then return rows_mon(ctx) end
  return rows_term(ctx, w)
end

function A.status(ctx)
  local ix = S.index
  if not ix then return S.pass and "считаю…" or nil end
  if ix.n_invs == 0 and not ix.me_on then return "нет сундуков" end
  local s = fmt(ix.total) .. " шт."
  if #S.low > 0 then s = s .. ", мало: " .. #S.low
  elseif #S.tasks > 0 then s = s .. ", плавка" end
  return s
end

local ROLE_WORD = { issue = "«Выдача»", intake = "«Приёмка»", misc = "«Разное»" }

-- Назначить сундук «Выдачей», «Приёмкой» или «Разным» (name = "" — убрать «Приёмку»/«Разное»). -> ok, текст
local function set_role(ctx, mode, name)
  local d = ctx.data
  if not ROLE_WORD[mode] then return false, "роль: issue, intake или misc" end
  if name == "" then
    if mode == "issue" then return false, "«Выдача» нужна — выберите другой сундук" end
    d[mode] = nil; ctx.save(); S.soon = true
    return true, ROLE_WORD[mode] .. " больше нет."
  end
  if not is_inv(name) then return false, "Нет такого инвентаря: " .. name end
  local role = role_of(ctx, name)
  if role == "core" or role == "memory" or role == "bridge" or role == "furnace" then
    return false, "Это " .. ROLE_LABEL[role] .. " — выберите другой сундук."
  end
  for other in pairs(ROLE_WORD) do
    if other ~= mode and d[other] == name then return false, "Этот сундук уже " .. ROLE_WORD[other] .. " — выберите другой." end
  end
  if flow_chests(ctx)[name] then return false, "Этот сундук — в конвейере." end
  d[mode] = name
  ctx.save()
  S.soon = true
  return true, ROLE_WORD[mode] .. " теперь: " .. Chest.title(ctx, name) .. (mode ~= "misc" and " (не считается складом)." or ".")
end

local function chest_err(ctx, err, opts)
  if not opts or #opts == 0 then return err end
  local o = {}
  for i = 1, math.min(4, #opts) do o[#o + 1] = Chest.title(ctx, opts[i]) end
  return err .. " " .. table.concat(o, ", ")
end

function A.action(ctx, act)
  local op = act.op
  local d = ctx.data
  if op == "find" then
    S.query = u8.trim(tostring(act.value or ""))
    S.offer = nil
    if S.query == "" then S.results = {}; say_msg("Поиск сброшен.", colors.lightGray); return end
    ensure_index(ctx)
    S.results = search(S.query, C.RESULTS_MAX)
    say_msg(#S.results > 0 and ("Найдено: " .. #S.results .. ". Enter — выдать, Delete — следить.")
      or ("По «" .. S.query .. "» ничего нет."), #S.results > 0 and colors.lightGray or colors.orange)
  elseif op == "take" then
    local id = act.id
    local total = have(id)
    local v = norm(act.value)
    local n
    if v == "" then n = math.max(1, math.min(64, total))
    elseif v == "все" then n = math.min(total, C.MAX_TAKE)
    else n = tonumber(v:match("^[0-9]+$") or "") end
    if not n or n < 1 then say_msg("Сколько выдать? Введите число или «все».", colors.orange); return end
    local r, err = take(ctx, id, n, act.player)
    if not r then say_msg("Не выдано: " .. tostring(err), colors.orange); S.offer = nil; return end
    say_msg(take_text(r), r.missing and colors.orange or colors.lime)
    S.offer = r.craftable and { id = id, count = r.missing } or nil
  elseif op == "craft" then
    local r, err = craft(ctx, act.id, act.count, act.player)
    S.offer = nil
    if not r then say_msg("Не заказано: " .. tostring(err), colors.orange)
    elseif r.status == "needs_confirmation" then
      local s = "Крупный заказ «" .. name_of(act.id) .. "» ×" .. act.count .. ": напишите в чате «да " .. r.code .. "» (2 мин.)"
      say_msg(s, colors.yellow)
      ctx.say("Склад: " .. s, "sys")
    else
      say_msg("Заказ принят: «" .. name_of(act.id) .. "» ×" .. act.count .. ". Готовое — в МЭ.", colors.lime)
    end
  elseif op == "offer_cancel" then
    S.offer = nil
  elseif op == "watch_quick" then
    local ok, err = set_watch(ctx, act.id, (find_watch(ctx, act.id) or {}).min or 64)
    say_msg(ok and ("Слежу: «" .. name_of(act.id) .. "» — не меньше " .. find_watch(ctx, act.id).min .. ". Минимум — в «Наблюдении».")
      or ("Не добавлено: " .. tostring(err)), ok and colors.lime or colors.orange)
  elseif op == "watch_new" then
    local v = u8.trim(tostring(act.value or ""))
    local what, n = v:match("^(.-)[ \t]+([0-9]+)$")
    if not what then what, n = v, "64" end
    if what == "" then say_msg("Напишите название и минимум: «железный слиток 64».", colors.orange); return end
    ensure_index(ctx)
    local id, cands = resolve(what)
    if not id then say_msg("Не нашёл «" .. what .. "» на складе — уточните или введите ID.", colors.orange); return end
    local ok, err = set_watch(ctx, id, tonumber(n))
    if not ok then say_msg("Не добавлено: " .. tostring(err), colors.orange); return end
    local others = {}
    for i = 2, math.min(3, #cands) do others[#others + 1] = name_of(cands[i]) end
    say_msg("Слежу: «" .. name_of(id) .. "» — не меньше " .. n .. (#others > 0 and (" (ещё похожие: " .. table.concat(others, ", ") .. ")") or ""),
      colors.lime)
  elseif op == "watch_set" then
    local n = tonumber(tostring(act.value or ""):match("^[ \t]*([0-9]+)[ \t]*$") or "")
    if not n then say_msg("Минимум — число (0 — не следить).", colors.orange); return end
    set_watch(ctx, act.id, n)
    say_msg(n > 0 and ("Минимум «" .. name_of(act.id) .. "»: " .. n) or ("Больше не слежу за «" .. name_of(act.id) .. "»."), colors.lime)
  elseif op == "watch_del" then
    set_watch(ctx, act.id, 0)
    say_msg("Больше не слежу за «" .. name_of(act.id) .. "».", colors.lightGray)
  elseif op == "pick" then
    S.pick = act.mode or "issue"
  elseif op == "pick_cancel" then
    S.pick = nil
  elseif op == "pick_set" then
    local mode, name = act.mode, tostring(act.name or "")
    S.pick = nil
    if mode == "sort" then
      if not is_inv(name) then say_msg("Нет такого инвентаря: " .. name, colors.orange); return end
      local role = role_of(ctx, name)
      if role == "core" or role == "memory" or role == "bridge" or role == "furnace" then
        say_msg("Это " .. ROLE_LABEL[role] .. " — выберите другой сундук.", colors.orange); return
      end
      ensure_index(ctx)
      S.sort_job = { src = name, moved = 0, st = { stuck = {} } }
      say_msg("Разбираю " .. Chest.title(ctx, name) .. "…", colors.lightGray)
      return
    end
    local ok, msg = set_role(ctx, mode, name)
    say_msg(msg, ok and colors.lime or colors.orange)
  elseif op == "issue" then   -- совместимость
    A.action(ctx, { op = "pick_set", mode = "issue", name = act.name })
  elseif op == "inv" then
    local name = tostring(act.name or "")
    if not is_inv(name) then return end
    d.inv[name] = act.on and true or false
    ctx.save()
    S.soon = true
    say_msg(Chest.title(ctx, name) .. (act.on and " — теперь склад." or " — исключён из склада."), colors.lightGray)
  elseif op == "rename" then
    local ok, err = Chest.rename(ctx, tostring(act.name or ""), act.value)
    say_msg(ok and ("Сундук " .. (d.nums[act.name] and ("№" .. d.nums[act.name]) or act.name) .. ": " ..
      (d.labels[act.name] and ("«" .. d.labels[act.name] .. "»") or "без имени")) or ("Не переименован: " .. tostring(err)),
      ok and colors.lime or colors.orange)
  elseif op == "me" then
    d.use_me = d.use_me == false
    ctx.save(); S.soon = true
    say_msg(d.use_me and "МЭ-сеть учитывается." or "МЭ-сеть не учитывается.", colors.lightGray)
  elseif op == "overflow" then
    d.overflow_me = d.overflow_me == false
    ctx.save()
    say_msg(d.overflow_me and "Лишнее — в МЭ." or "Лишнее в МЭ не кладу (только правила, «где уже лежит», «Разное»).", colors.lightGray)
  elseif op == "mode" then
    d.mode = d.mode == "chosen" and "all" or "chosen"
    ctx.save(); S.soon = true
    say_msg(d.mode == "chosen" and "Склад — только отмеченные инвентари (Delete на строке — отметить)."
      or "Склад — все инвентари сети, кроме исключённых.", colors.lightGray)
  elseif op == "rule_add" or op == "rule_set" then
    ensure_index(ctx)
    local r, err, opts = Sort.parse(ctx, act.value)
    if not r then say_msg("Правило не добавлено: " .. chest_err(ctx, err, opts), colors.orange); return end
    local ok, err2 = Sort.add(ctx, r, op == "rule_set" and act.n or nil)
    say_msg(ok and ("Правило: " .. Spec.label(r) .. " → " .. Chest.title(ctx, r.to)) or ("Не добавлено: " .. tostring(err2)),
      ok and colors.lime or colors.orange)
  elseif op == "rule_del" then
    local r = Sort.remove(ctx, act.n)
    say_msg(r and ("Правило удалено: " .. Spec.label(r)) or "Нет такого правила.", colors.lightGray)
  elseif op == "smelt_add" then
    local v = u8.trim(tostring(act.value or ""))
    local what, n = v:match("^(.-)[ \t]+([0-9]+)$")
    if not what then what = v end
    local t, err, sum, avail = Smelt.request(ctx, what, n, act.player)
    if not t then say_msg("Не плавлю: " .. tostring(err), colors.orange); return end
    say_msg("Плавлю «" .. t.label .. "»" .. (t.left and (" ×" .. t.left) or (" (на складе " .. avail .. ")")) ..
      "; печей с загрузкой: " .. sum.load .. ", с выходом: " .. sum.out .. ".", sum.load > 0 and colors.lime or colors.orange)
  elseif op == "smelt_stop" then
    local n, back = Smelt.stop(ctx, act.n)
    say_msg(n > 0 and ("Переплавка остановлена; вернул из печей " .. back .. " шт.") or "Нечего останавливать.", colors.lightGray)
  elseif op == "flow_add" then
    ensure_index(ctx)
    local f, err, opts = Flow.parse_add(ctx, act.value)
    if not f then say_msg("Конвейер не добавлен: " .. chest_err(ctx, err, opts), colors.orange); return end
    say_msg("Конвейер " .. flow_title(ctx, f), colors.lime)
  elseif op == "flow_del" then
    local f = Flow.remove(ctx, act.n)
    say_msg(f and ("Конвейер №" .. f.n .. " удалён.") or "Нет такого конвейера.", colors.lightGray)
  end
end

-- ---------- нейросеть ----------
local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end
local function Str(dsc) return { type = "string", description = dsc } end
local function Int(dsc) return { type = "integer", description = dsc } end
local CHEST_HINT = "сундук: имя («руды»), номер (7), «новый» (последний подключённый), «пустой» или «где лежит X»"

function A.tools(ctx, tctx)
  local ix = S.index
  if ix and ix.n_invs == 0 and not ix.me_on and #(ctx.data.watch or {}) == 0 and #classify(ctx) == 0 then return {} end
  return {
    { name = "storage_find", description = "Найти предмет на складе: сундуки сети И МЭ (me_find видит только МЭ). Вернёт ID, название, сколько и где.",
      parameters = obj({ query = Str("часть названия или ID: «железный слиток», «алмаз», minecraft:coal") }, { "query" }) },
    { name = "storage_take", description = "Выдать предмет спросившему: в сундук «Выдача» из сундуков и МЭ. Не хватает — скажет, может ли МЭ скрафтить (тогда предложи me_craft).",
      parameters = obj({ item = Str("ID из storage_find или название"), count = Int("сколько, 1.." .. C.MAX_TAKE) }, { "item", "count" }) },
    { name = "storage_watch", description = "Наблюдение за запасом: тревога, когда меньше минимума. min=0 — не следить. Без item — список.",
      parameters = obj({ item = Str("ID или название предмета"), min = Int("минимум; 0 — убрать") }) },
    { name = "storage_chests", description = "Сундуки сети: номер, имя от игрока, роль, заполненность, что лежит, new — подключён недавно. Для переспроса «какой сундук?».",
      parameters = obj({}) },
    { name = "storage_name_chest", description = "Дать сундуку имя (игрок потом говорит «в сундук руды») и/или роль: issue — «Выдача», intake — «Приёмка» (всё оттуда раскладывается само), misc — «Разное». Имя с наковальни CC не видит — называть только так.",
      parameters = obj({ chest = Str(CHEST_HINT), name = Str("новое имя, до 24 символов; пусто — убрать; не указывать — не менять"),
        role = { type = "string", enum = { "issue", "intake", "misc" }, description = "необязательно: назначить роль" } }, { "chest" }) },
    { name = "storage_sort_rule", description = "Правила сортировки «что → куда» (для «Приёмки» и разбора сундуков): add, remove (по n), list.",
      parameters = obj({ action = { type = "string", enum = { "add", "remove", "list" } },
        what = Str("предмет, мод (create:), тег (#c:ingots) или категория: руды, слитки, еда, дерево, камень, инструменты…"),
        to = Str(CHEST_HINT .. " или «МЭ»"), n = Int("номер правила для remove") }, { "action" }) },
    { name = "storage_sort_now", description = "Разложить сейчас: «Приёмку» (по умолчанию) или указанный сундук — по правилам, к таким же, в МЭ, в «Разное».",
      parameters = obj({ chest = Str("необязательно; " .. CHEST_HINT) }) },
    { name = "storage_smelt", description = "Переплавить со склада в печах сети (уголь — со склада, готовое — на склад). count=0 — всё.",
      parameters = obj({ what = Str("предмет или категория: «руды» (руда и сырьё), «песок», «железная руда»"), count = Int("сколько; 0 — всё") }, { "what" }) },
    { name = "storage_smelt_status", description = "Печи (какие модемы: загрузка/выход), очередь переплавки, сколько готово, проблемы.", parameters = obj({}) },
    { name = "storage_smelt_stop", description = "Остановить разовую переплавку (n или все); загруженное вернётся на склад.",
      parameters = obj({ n = Int("номер задания; без него — все") }) },
    { name = "storage_flow_add", description = "Постоянный конвейер: из сундука → действие → куда. Пример: руды → smelt → «из печи». Сундуки конвейера не выдаются со склада.",
      parameters = obj({ from = Str(CHEST_HINT), action = { type = "string", enum = { "smelt", "move", "sort", "me" },
        description = "smelt — переплавить, move — переложить, sort — разложить по правилам склада, me — в МЭ" },
        to = Str("куда: " .. CHEST_HINT .. ", «склад» или «МЭ»"), filter = Str("необязательно: категория, тег, мод или предмет") }, { "from", "action" }) },
    { name = "storage_flow_list", description = "Конвейеры: номер, откуда, действие, куда, фильтр, состояние.", parameters = obj({}) },
    { name = "storage_flow_remove", description = "Удалить конвейер по номеру.", parameters = obj({ n = Int("номер конвейера") }, { "n" }) },
  }
end

local function clean_take(r)
  r.text = take_text(r)
  return r
end

local function ask_chest(ctx, err, opts)
  if opts and #opts > 0 then return { need_choice = true, question = err, options = options(ctx, opts) } end
  return "отказ: " .. tostring(err)
end

local function smelt_note(sum)
  if sum.views == 0 then return "печей в сети нет — подключите печь проводными модемами сверху и снизу" end
  if sum.load == 0 then return "у печей нет модема СВЕРХУ (загрузка) — без него не загрузить" end
  if sum.out == 0 then return "у печей нет модема СНИЗУ — готовое и топливо не достать" end
  return "печей с загрузкой: " .. sum.load .. ", с выходом: " .. sum.out
end

function A.run_tool(ctx, name, args, tctx)
  local player = nick(tctx and tctx.player)
  local d = ctx.data
  if name == "storage_find" then
    ensure_index(ctx)
    local q = tostring(args.query or ""):sub(1, 64)
    local out = {}
    for _, id in ipairs(search(q, 15)) do out[#out + 1] = describe(ctx, id) end
    local res = { found = #out, items = out, issue_chest = d.issue and Chest.title(ctx, d.issue) or "не выбран" }
    if #out == 0 then
      res.note = "ничего не нашлось; сундуков в складе: " .. (S.index and S.index.n_invs or 0) ..
        ", МЭ: " .. ((S.index and S.index.me_on) and "да" or "нет")
    end
    return res
  elseif name == "storage_take" then
    local id = tostring(args.item or ""):sub(1, 100)
    if not valid_id(id) then
      ensure_index(ctx)
      id = resolve(id)
      if not id then return "отказ: не нашёл такой предмет — сначала storage_find" end
    end
    local r, err = take(ctx, id, args.count, player)
    if not r then return "отказ: " .. tostring(err) end
    return clean_take(r)
  elseif name == "storage_watch" then
    local item = tostring(args.item or ""):sub(1, 100)
    if item == "" then
      local list = {}
      for _, w in ipairs(d.watch) do
        list[#list + 1] = { id = w.id, name = watch_name(w), min = w.min, have = S.index and have(w.id) or nil }
      end
      return { watch = list }
    end
    local id = item
    if not valid_id(id) then
      ensure_index(ctx)
      id = resolve(item)
      if not id then return "отказ: не нашёл такой предмет на складе — укажи точный ID" end
    end
    local min = math.floor(tonumber(args.min) or 0)
    local ok, err = set_watch(ctx, id, min)
    if not ok then return "отказ: " .. tostring(err) end
    if min <= 0 then return "больше не слежу за «" .. name_of(id) .. "»" end
    return "слежу: «" .. name_of(id) .. "» (" .. id .. ") — не меньше " .. min .. ", сейчас " ..
      (S.index and fmt(have(id)) or "?") .. (player and (" (просил " .. player .. ")") or "")
  elseif name == "storage_chests" then
    ensure_index(ctx)
    Chest.sync(ctx)
    local o = {}
    for _, c in ipairs(candidates(ctx, { any = true })) do o[#o + 1] = Chest.brief(ctx, c.name, c.role) end
    return { chests = o, note = "имя с наковальни CC не видит — называй через storage_name_chest" }
  elseif name == "storage_name_chest" then
    ensure_index(ctx)
    Chest.sync(ctx)
    local n, err, opts = Chest.which(ctx, args.chest, { any = true })
    if not n then return ask_chest(ctx, err, opts) end
    local parts = {}
    if args.name ~= nil then
      local ok, err2 = Chest.rename(ctx, n, args.name)
      if not ok then return "отказ: " .. tostring(err2) end
      parts[#parts + 1] = "Сундук №" .. tostring(d.nums[n]) .. " теперь «" .. tostring(d.labels[n] or "без имени") .. "»"
    end
    if args.role and args.role ~= "" then
      local ok, msg = set_role(ctx, tostring(args.role), n)
      if not ok then return "отказ: " .. msg end
      parts[#parts + 1] = msg
    end
    if #parts == 0 then return "отказ: укажи name и/или role" end
    return { ok = true, chest = Chest.brief(ctx, n), text = table.concat(parts, "; ") }
  elseif name == "storage_sort_rule" then
    local a = tostring(args.action or "list")
    if a == "list" then
      local o = {}
      for _, r in ipairs(d.rules) do o[#o + 1] = Sort.describe(ctx, r) end
      return { rules = o, intake = d.intake and Chest.title(ctx, d.intake) or "не выбрана", misc = d.misc and Chest.title(ctx, d.misc) or nil,
        overflow_to_me = d.overflow_me ~= false }
    elseif a == "remove" then
      local r = Sort.remove(ctx, tonumber(args.n))
      return r and ("удалено правило №" .. r.n) or "отказ: нет правила с таким номером"
    elseif a == "add" then
      ensure_index(ctx)
      local r, err, opts = Sort.parse(ctx, tostring(args.what or "") .. " > " .. tostring(args.to or ""))
      if not r then return ask_chest(ctx, err, opts) end
      local ok, err2 = Sort.add(ctx, r)
      if not ok then return "отказ: " .. tostring(err2) end
      return { ok = true, rule = Sort.describe(ctx, r), note = d.intake and "работает для «Приёмки» и разбора сундуков"
        or "сундук «Приёмка» не выбран — правило сработает при storage_sort_now или после выбора «Приёмки»" }
    end
    return "отказ: action = add | remove | list"
  elseif name == "storage_sort_now" then
    ensure_index(ctx)
    local src = d.intake
    if args.chest and tostring(args.chest) ~= "" then
      local n, err, opts = Chest.which(ctx, args.chest)
      if not n then return ask_chest(ctx, err, opts) end
      src = n
    end
    if not is_inv(src) then return "отказ: «Приёмка» не выбрана — укажи сундук или выбери «Приёмку» на вкладке «Склад»" end
    local r = Sort.now(ctx, src, 400)
    return { chest = Chest.title(ctx, src), moved = r.moved, left_kinds = r.left, done = r.done,
      text = "Разложено " .. r.moved .. " шт. из " .. Chest.title(ctx, src) .. ((r.left or 0) > 0 and ("; некуда положить видов: " .. r.left) or "") }
  elseif name == "storage_smelt" then
    local what = tostring(args.what or ""):sub(1, 60)
    local t, err, sum, avail = Smelt.request(ctx, what, args.count, player)
    if not t then return "отказ: " .. tostring(err) end
    return { ok = true, n = t.n, what = t.label, count = t.left or avail, queue_position = #S.tasks, furnaces = smelt_note(sum) }
  elseif name == "storage_smelt_status" then
    S.views = Smelt.views(ctx, nil)
    local st = Smelt.status(ctx)
    st.note = smelt_note(Smelt.summary(S.views))
    return st
  elseif name == "storage_smelt_stop" then
    local n, back = Smelt.stop(ctx, args.n and tonumber(args.n) or nil)
    return n > 0 and ("остановлено заданий: " .. n .. ", из печей вернул " .. back .. " шт.") or "нечего останавливать"
  elseif name == "storage_flow_add" then
    ensure_index(ctx)
    Chest.sync(ctx)
    local action = tostring(args.action or "")
    local f, err, opts = Flow.add(ctx, args.from, ACTION_WORD[action] or action, args.to, args.filter)
    if not f then return ask_chest(ctx, err, opts) end
    local res = { ok = true, flow = Flow.describe(ctx, f) }
    if f.action == "smelt" then res.furnaces = smelt_note(Smelt.summary(Smelt.views(ctx, nil))) end
    return res
  elseif name == "storage_flow_list" then
    local o = {}
    for _, f in ipairs(d.flows) do o[#o + 1] = Flow.describe(ctx, f) end
    return { flows = o }
  elseif name == "storage_flow_remove" then
    local f = Flow.remove(ctx, tonumber(args.n))
    return f and ("удалён конвейер №" .. f.n) or "отказ: нет конвейера с таким номером"
  end
  return "нет такого инструмента"
end

-- ---------- КПК ----------
A.radio = {
  find = function(ctx, msg)
    ensure_index(ctx)
    local out = {}
    for _, id in ipairs(search(tostring(msg.query or ""):sub(1, 64), 10)) do out[#out + 1] = describe(ctx, id) end
    return { items = out }
  end,
  take = function(ctx, msg, sender, player)
    local r, err = take(ctx, tostring(msg.item or ""), msg.count, player)
    if not r then return nil, err end
    return clean_take(r)
  end,
  low = function(ctx)
    return { low = S.low, total = S.index and S.index.total or 0 }
  end,
}

-- ---------- для тестов ----------
A._state = function() return S end
A._rescan = function(ctx)
  S.pass = nil
  start_pass(ctx)
  local p = S.pass
  local n = 0
  while S.pass == p and n < 1000 do scan_step(ctx, 1000); n = n + 1 end
  detail_step(1000)
end
A._search = search
A._fmt = fmt
A._which = function(ctx, q, opts) return Chest.which(ctx, q, opts) end
A._spec = Spec
A._smelt_step = function(ctx, calls) Smelt.step(ctx, { left = calls or 1000 }) end
A._flow_step = function(ctx, calls) Flow.step(ctx, { left = calls or 1000 }) end
A._intake_step = function(ctx, calls) Sort.intake_step(ctx, { left = calls or 1000 }) end
A._sort_job_step = function(ctx, calls) return Sort.job_step(ctx, { left = calls or 1000 }) end

return A
