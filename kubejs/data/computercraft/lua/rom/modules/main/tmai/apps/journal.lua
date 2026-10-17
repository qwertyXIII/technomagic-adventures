-- tmai/apps/journal.lua — приложение «Журнал»: хроника экспедиции.
--
-- Запись: { id, day = os.day(), tm = os.time() (игровое время), t (реальное, сек), kind, by (автор), src, text }.
--   kind: note — заметка экипажа (терминал, КПК или через ЛОЦМАНа), death — гибель, dim — первый визит игрока
--   в измерение, boss — победа над боссом. src: term | kpk | ai | auto. Удалить можно только заметку.
-- Вкладка: «+ Новая запись» (ввод внизу), записи новыми сверху по дням; Enter — прочитать целиком, Delete — удалить.
-- Автозаписи (tick раз в 15 с, нужен штурманский модуль TM-NAV, операции — /rom/modules/main/tmnav/journal.lua):
--   journal_scan  — счёт гибелей (scoreboard deathCount) и измерение игроков онлайн;
--   journal_death — где игрок погиб в последний раз (LastDeathLocation);
--   journal_kills — счёт убийств боссов (scoreboard minecraft.killed:…), по BOSS_BATCH целей за раз по кругу.
--   Первое наблюдение игрока — только отсчёт (без записи), записи — при росте счёта или новом измерении.
-- Тревоги «Базы» в журнал не попадают. Хранится не больше MAX_ENTRIES записей: лишние автоматические уходят
-- первыми (старые), заметки — только если автоматических не осталось.
-- Инструменты нейросети: journal_add, journal_list, journal_search.

local text = require("tmai.text")
local util = require("tmai.util")
local json = require("tmai.json")
local u8 = require("tmai.u8")

local M = { id = "journal", title = "Журнал", short = "Журн", order = 70, every = 15 }

local MAX_ENTRIES = 500
local TEXT_MAX = 240     -- символов в записи
local PAGE = 100         -- записей на экране (дальше — «показать ещё»)
local BOSS_BATCH = 4     -- целей за один опрос (каждая — команда на игрока)
local MAX_PLAYERS = 8
local RETRY = 60         -- модуль не ответил — следующая попытка через столько секунд

-- Боссы: id сущности (как в /summon) и имя по-русски. Дополнять можно прямо здесь — модуль TM-NAV
-- сам заведёт счёт (scoreboard minecraft.killed:<id>) при первом опросе.
M.BOSSES = {
  { id = "minecraft:wither", name = "Иссушитель" },
  { id = "minecraft:ender_dragon", name = "Эндер-дракон" },
  { id = "minecraft:warden", name = "Хранитель" },
  { id = "aether:slider", name = "Слайдер" },
  { id = "aether:valkyrie_queen", name = "Королева валькирий" },
  { id = "aether:sun_spirit", name = "Дух Солнца" },
  { id = "twilightforest:naga", name = "Нага" },
  { id = "twilightforest:lich", name = "Лич" },
  { id = "twilightforest:minoshroom", name = "Гриботавр" },
  { id = "twilightforest:hydra", name = "Гидра" },
  { id = "twilightforest:ur_ghast", name = "Древний гаст" },
  { id = "twilightforest:alpha_yeti", name = "Альфа-йети" },
  { id = "twilightforest:snow_queen", name = "Снежная королева" },
  { id = "cataclysm:ender_guardian", name = "Эндер-хранитель" },
  { id = "cataclysm:netherite_monstrosity", name = "Незеритовое чудище" },
  { id = "cataclysm:ignis", name = "Игнис" },
  { id = "cataclysm:the_harbinger", name = "Предвестник" },
  { id = "cataclysm:the_leviathan", name = "Левиафан" },
  { id = "cataclysm:ancient_remnant", name = "Древние Останки" },
  { id = "cataclysm:maledictus", name = "Маледиктус" },
  { id = "cataclysm:scylla", name = "Сцилла" },
  { id = "mowziesmobs:ferrous_wroughtnaut", name = "Кованый" },
  { id = "mowziesmobs:frostmaw", name = "Дубак" },
  { id = "mowziesmobs:umvuthi", name = "Умвути" },
  { id = "mowziesmobs:sculptor", name = "Тонгби Скульптор" },
  { id = "irons_spellbooks:dead_king", name = "Мёртвый король" },
}

-- Измерения по-русски (остальные — по имени из id).
M.DIMS = {
  ["minecraft:overworld"] = "Верхний мир", ["minecraft:the_nether"] = "Незер", ["minecraft:the_end"] = "Энд",
  ["aether:the_aether"] = "Эфир", ["twilightforest:twilight_forest"] = "Сумеречный лес",
  ["undergarden:undergarden"] = "Андергарден",
  ["ad_astra:moon"] = "Луна", ["ad_astra:mars"] = "Марс", ["ad_astra:venus"] = "Венера",
  ["ad_astra:mercury"] = "Меркурий", ["ad_astra:glacio"] = "Глацио",
  ["ad_astra:earth_orbit"] = "Орбита Земли", ["ad_astra:moon_orbit"] = "Орбита Луны",
  ["ad_astra:mars_orbit"] = "Орбита Марса", ["ad_astra:venus_orbit"] = "Орбита Венеры",
  ["ad_astra:mercury_orbit"] = "Орбита Меркурия", ["ad_astra:glacio_orbit"] = "Орбита Глацио",
}

local KIND_RU = { note = "заметка", death = "гибель", dim = "новое измерение", boss = "победа над боссом" }
local KIND_FG = { note = colors.white, death = colors.red, dim = colors.lightBlue, boss = colors.orange }
local SRC_RU = { term = "терминал", kpk = "КПК", ai = "через ЛОЦМАНа", auto = "автозапись" }

-- Только память: экран и состояние автозаписей.
local J = { reading = nil, limit = PAGE, auto_note = nil, boss_i = 1 }

-- ---------- данные ----------
local function valid(n) return type(n) == "string" and #n >= 3 and #n <= 16 and n:match("^[A-Za-z0-9_]+$") ~= nil end

local function dim_name(dim)
  if type(dim) ~= "string" then return "?" end
  return M.DIMS[dim] or ((dim:match(":(.+)$") or dim):gsub("[_/]", " "))
end

local function clean(s, max)
  s = tostring(s or ""):gsub("[%z\1-\31\127]", " ")
  s = s:gsub("  +", " "):gsub("^ +", ""):gsub(" +$", "")
  max = max or TEXT_MAX
  if text.len(s) > max then s = text.sub(s, 1, max) end
  return s
end

local function fmt_time(tm)
  if type(tm) ~= "number" then return "--:--" end
  local ok, s = pcall(textutils.formatTime, tm, true)
  return ok and tostring(s) or "--:--"
end

local function ensure(ctx)
  local d = ctx.data
  for _, k in ipairs({ "entries", "deaths", "dims", "kills" }) do
    if type(d[k]) ~= "table" then d[k] = {} end
  end
  d.next_id = tonumber(d.next_id) or (#d.entries + 1)
end

local function trim(ctx)
  local E = ctx.data.entries
  while #E > MAX_ENTRIES do
    local idx = 1
    for i, e in ipairs(E) do if e.kind ~= "note" then idx = i; break end end
    table.remove(E, idx)
  end
end

local function add_entry(ctx, kind, by, src, body)
  ensure(ctx)
  local id = ctx.data.next_id
  ctx.data.next_id = id + 1
  local tm = tonumber(os.time()) or 0
  local e = { id = id, day = tonumber(os.day()) or 0, tm = math.floor(tm * 100 + 0.5) / 100, t = math.floor(util.now()),
    kind = kind, by = by, src = src, text = body }
  local E = ctx.data.entries
  E[#E + 1] = e
  trim(ctx)
  return e
end

local function find(ctx, id)
  id = tonumber(id)
  for i, e in ipairs(ctx.data.entries) do if e.id == id then return e, i end end
  return nil
end

local function export(e)
  return { id = e.id, day = e.day, time = fmt_time(e.tm), by = e.by, kind = KIND_RU[e.kind] or e.kind,
    source = SRC_RU[e.src] or e.src, text = e.text }
end

-- ---------- жизненный цикл ----------
function M.init(ctx)
  ensure(ctx)
end

local function online_players(ctx)
  local out, seen = {}, {}
  local ok, list = pcall(ctx.online)
  for _, n in ipairs(ok and type(list) == "table" and list or {}) do
    if valid(n) and not seen[n] then out[#out + 1] = n; seen[n] = true end
    if #out >= MAX_PLAYERS then break end
  end
  table.sort(out)
  return out
end

local function check_death(ctx, name, info)
  local d = tonumber(info.deaths)
  if not d then return false end
  local D = ctx.data.deaths
  local prev = tonumber(D[name])
  if prev == nil or d < prev then D[name] = d; return true end   -- отсчёт (или счёт сброшен)
  if d == prev then return false end
  D[name] = d
  local s = "Гибель " .. name .. (d - prev > 1 and (" (x" .. (d - prev) .. ")") or "")
  local where = ctx.nav("journal_death", { player = name })
  if type(where) == "table" and tonumber(where.x) and tonumber(where.y) and tonumber(where.z) then
    s = s .. " — " .. dim_name(where.dim) .. string.format(", X %d Y %d Z %d",
      math.floor(tonumber(where.x)), math.floor(tonumber(where.y)), math.floor(tonumber(where.z)))
  end
  add_entry(ctx, "death", name, "auto", s .. ". Всего гибелей: " .. d)
  return true
end

local function check_dim(ctx, name, info)
  local dim = info.dim
  if type(dim) ~= "string" or not dim:match("^[a-z0-9_%.%-]+:[a-z0-9_%.%-/]+$") then return false end
  local DM = ctx.data.dims
  local seen = DM[name]
  if type(seen) ~= "table" then                 -- первое наблюдение: отсчёт, Верхний мир — уже «был»
    DM[name] = { ["minecraft:overworld"] = os.day() }
    DM[name][dim] = os.day()
    return true
  end
  if seen[dim] then return false end
  seen[dim] = os.day()
  add_entry(ctx, "dim", name, "auto", name .. " впервые в измерении «" .. dim_name(dim) .. "»")
  return true
end

local function check_bosses(ctx, players)
  local n = #M.BOSSES
  if n == 0 then return false end
  local ids, by_id = {}, {}
  local start = ((tonumber(J.boss_i) or 1) - 1) % n
  for k = 0, math.min(BOSS_BATCH, n) - 1 do
    local b = M.BOSSES[(start + k) % n + 1]
    ids[#ids + 1] = b.id
    by_id[b.id] = b
  end
  J.boss_i = (start + #ids) % n + 1
  local r = ctx.nav("journal_kills", { players = players, targets = ids })
  if type(r) ~= "table" or type(r.kills) ~= "table" then return false end
  local K, changed = ctx.data.kills, false
  for _, name in ipairs(players) do
    local per = r.kills[name]
    if type(per) == "table" then
      if type(K[name]) ~= "table" then K[name] = {} end
      for _, id in ipairs(ids) do
        local cnt = tonumber(per[id])
        if cnt then
          local prev = tonumber(K[name][id])
          if prev == nil or cnt < prev then
            K[name][id] = cnt; changed = true
          elseif cnt > prev then
            K[name][id] = cnt; changed = true
            add_entry(ctx, "boss", name, "auto", "Побеждён босс «" .. by_id[id].name .. "» — " .. name ..
              (cnt - prev > 1 and (" (x" .. (cnt - prev) .. ")") or ""))
          end
        end
      end
    end
  end
  return changed
end

function M.tick(ctx)
  ensure(ctx)
  local players = online_players(ctx)
  if #players == 0 then J.auto_note = nil; return end
  -- модуль не отвечал: не ждать его таймаут каждые 15 с (tick-и приложений идут по очереди)
  if J.retry_at and util.now() < J.retry_at then return end
  local r, err = ctx.nav("journal_scan", { players = players })
  if type(r) ~= "table" or type(r.players) ~= "table" then
    J.auto_note = "Автозаписи ждут штурманский модуль: " .. tostring(err or "нет ответа")
    J.retry_at = util.now() + RETRY
    return
  end
  J.auto_note, J.retry_at = nil, nil
  local changed = false
  for _, name in ipairs(players) do
    local info = r.players[name]
    if type(info) == "table" then
      if check_death(ctx, name, info) then changed = true end
      if check_dim(ctx, name, info) then changed = true end
    end
  end
  if check_bosses(ctx, players) then changed = true end
  if changed then ctx.save() end
end

-- ---------- действия экрана ----------
local function delete(ctx, id)
  local e, i = find(ctx, id)
  if not e or e.kind ~= "note" then return false end
  table.remove(ctx.data.entries, i)
  if J.reading == e.id then J.reading = nil end
  return true
end

function M.action(ctx, act)
  ensure(ctx)
  local op = act.op
  if op == "add" then
    local s = clean(act.value)
    if s == "" then return end
    add_entry(ctx, "note", valid(act.player) and act.player or "Экипаж", "term", s)
    ctx.save()
  elseif op == "read" then
    J.reading = tonumber(act.id)
  elseif op == "close" then
    J.reading = nil
  elseif op == "del" then
    if delete(ctx, act.id) then ctx.save() end
  elseif op == "more" then
    J.limit = J.limit + PAGE
  end
end

-- ---------- экраны (ничего не ждут) ----------
local function entry_desc(e)
  local parts = { KIND_RU[e.kind] or tostring(e.kind) }
  if e.by then parts[#parts + 1] = e.by end
  if SRC_RU[e.src] then parts[#parts + 1] = SRC_RU[e.src] end
  return table.concat(parts, " · ")
end

local function entry_row(e)
  local body = tostring(e.text or "")
  if e.kind == "note" and e.by then body = e.by .. ": " .. body end
  local note = e.kind == "note"
  return {
    text = fmt_time(e.tm) .. " " .. body, fg = KIND_FG[e.kind] or colors.white,
    action = { op = "read", id = e.id, label = "читать" },
    del = note and { op = "del", id = e.id, label = "удалить" } or nil,
    desc = entry_desc(e),
    hint = note and "Enter — читать целиком · Delete — удалить" or "Enter — читать целиком",
  }
end

local function reader_rows(e, w)
  local note = e.kind == "note"
  local hint = note and "Enter — назад · Delete — удалить запись" or "Enter — назад к списку"
  local out = {
    { text = "< Назад к списку", fg = colors.lightGray, action = { op = "close", label = "назад" }, hint = "Enter — назад к списку" },
    { text = "День " .. tostring(e.day) .. ", " .. fmt_time(e.tm) .. " — " .. (KIND_RU[e.kind] or tostring(e.kind)), header = true },
  }
  for _, l in ipairs(text.wrap(tostring(e.text or ""), math.max(8, w - 2))) do
    out[#out + 1] = { text = l, fg = KIND_FG[e.kind] or colors.white, action = { op = "close", label = "назад" },
      del = note and { op = "del", id = e.id, label = "удалить" } or nil, desc = entry_desc(e), hint = hint }
  end
  out[#out + 1] = { text = "Автор: " .. tostring(e.by or "—") .. (SRC_RU[e.src] and (" (" .. SRC_RU[e.src] .. ")") or ""),
    fg = colors.lightGray }
  return out
end

function M.rows(ctx, w)
  ensure(ctx)
  w = tonumber(w) or 51
  if J.reading then
    local e = find(ctx, J.reading)
    if e then return reader_rows(e, w) end
    J.reading = nil
  end
  local E = ctx.data.entries
  local out = {
    { text = "+ Новая запись", fg = colors.lime, prompt = { label = "Запись", op = "add", max = TEXT_MAX },
      desc = "Запишется от вашего имени, с днём и временем.", hint = "Enter — написать запись" },
  }
  if J.auto_note then out[#out + 1] = { text = J.auto_note, fg = colors.gray } end
  if #E == 0 then
    out[#out + 1] = { text = "Журнал пуст. Гибели, новые измерения и победы", fg = colors.gray }
    out[#out + 1] = { text = "над боссами запишутся сами.", fg = colors.gray }
    return out
  end
  local last_day, shown = nil, 0
  for i = #E, 1, -1 do
    local e = E[i]
    if shown >= J.limit then
      out[#out + 1] = { text = "Ещё записей: " .. i, fg = colors.gray, action = { op = "more", label = "показать ещё" },
        hint = "Enter — показать ещё " .. PAGE }
      break
    end
    if e.day ~= last_day then
      out[#out + 1] = { text = "День " .. tostring(e.day), header = true }
      last_day = e.day
    end
    out[#out + 1] = entry_row(e)
    shown = shown + 1
  end
  return out
end

function M.status(ctx)
  local n = type(ctx.data.entries) == "table" and #ctx.data.entries or 0
  if n == 0 then return "пусто" end
  return "записей: " .. n
end

-- ---------- нейросеть ----------
local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end

function M.tools(ctx, tctx)
  return {
    { name = "journal_add", description = "Записать в журнал экспедиции заметку от спросившего игрока (что сделали, нашли, решили, где). Кратко, по-русски.",
      parameters = obj({ text = { type = "string", description = "текст записи, до 240 символов" } }, { "text" }) },
    { name = "journal_list", description = "Последние записи журнала экспедиции, новые сверху: заметки экипажа, гибели (с местом), первые визиты в измерения, победы над боссами.",
      parameters = obj({
        count = { type = "integer", description = "сколько записей, 1..30 (по умолчанию 10)" },
        kind = { type = "string", enum = { "note", "death", "dim", "boss" }, description = "только этого вида (необязательно)" },
      }) },
    { name = "journal_search", description = "Найти записи журнала по словам (ник, место, босс, измерение, что искали).",
      parameters = obj({
        query = { type = "string", description = "слова для поиска" },
        count = { type = "integer", description = "сколько найти, 1..20 (по умолчанию 10)" },
      }, { "query" }) },
  }
end

local function clamp(v, lo, hi, def)
  v = tonumber(v)
  if not v then return def end
  return math.max(lo, math.min(hi, math.floor(v)))
end

local function list_entries(ctx, count, kind)
  ensure(ctx)
  local E, out = ctx.data.entries, {}
  for i = #E, 1, -1 do
    if not kind or E[i].kind == kind then out[#out + 1] = export(E[i]) end
    if #out >= count then break end
  end
  return { total = #E, entries = #out > 0 and out or "записей нет" }
end

local function search(ctx, query, count)
  ensure(ctx)
  local words = {}
  for w in u8.lower(u8.trim(tostring(query or ""))):gmatch("[^ ]+") do words[#words + 1] = w end
  if #words == 0 then return "ошибка: пустой запрос" end
  local E, out, found = ctx.data.entries, {}, 0
  for i = #E, 1, -1 do
    local e = E[i]
    local hay = u8.lower(tostring(e.text or "") .. " " .. tostring(e.by or "") .. " " .. (KIND_RU[e.kind] or ""))
    local ok = true
    for _, w in ipairs(words) do if not hay:find(w, 1, true) then ok = false; break end end
    if ok then
      found = found + 1
      if #out < count then out[#out + 1] = export(e) end
    end
  end
  return { found = found, entries = #out > 0 and out or "ничего не найдено" }
end

local function add_from(ctx, s, player, src)
  s = clean(s)
  if s == "" then return nil, "пустой текст" end
  local e = add_entry(ctx, "note", valid(player) and player or "Экипаж", src, s)
  ctx.save()
  os.queueEvent("tmai_ui", "app")
  return { ok = true, id = e.id, day = e.day, time = fmt_time(e.tm) }
end

function M.run_tool(ctx, name, args, tctx)
  if name == "journal_add" then
    local r, err = add_from(ctx, args.text, tctx and tctx.player, "ai")
    return r or ("ошибка: " .. err)
  elseif name == "journal_list" then
    local kind = KIND_RU[args.kind] and args.kind or nil
    return list_entries(ctx, clamp(args.count, 1, 30, 10), kind)
  elseif name == "journal_search" then
    return search(ctx, args.query, clamp(args.count, 1, 20, 10))
  end
  return "нет такого инструмента"
end

-- ---------- КПК ----------
M.radio = {
  list = function(ctx, msg) return list_entries(ctx, clamp(msg.count, 1, 30, 10)) end,
  add = function(ctx, msg, sender, player) return add_from(ctx, msg.text, player, "kpk") end,
}

-- для тестов
M._state = J

return M
