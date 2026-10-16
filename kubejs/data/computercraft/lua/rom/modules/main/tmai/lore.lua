-- tmai.lore — память ЛОЦМАНа: слои, открываемые ключами из Ящика памяти, и «прочитанные» находки.
--
-- Данные (из сборки, генерируются tools/gen/build.py, тексты в «шторке» base64+XOR — от случайного `edit`):
--   /rom/tmai/lore/layers.tsv : layer, keys, title, file   — слой 0..9 и режимы после финала «10a/10b/10c»
--   /rom/tmai/lore/notes.tsv  : item, layer, title, file   — находки (записки, журналы)
--   <file>.dat — у слоя секции ##MEMORY (что ИИ теперь знает), ##RECORD (восстановленная запись), ##STYLE (характер)
-- Правила:
--   * ключ слоя хоть раз побывал в Ящике — слой открыт навсегда (state.keys);
--   * слой L восстановлен, только если открыты все слои 1..L (ключ «из будущего» ждёт своей очереди);
--   * находку ИИ понимает, если её слой <= восстановленного, иначе это «фрагмент без контекста»;
--   * в промпт попадают ТОЛЬКО восстановленные слои и понятые находки — закрытого модель не видит.
-- Состояние — в общем state (/tmai/state.json).

local util = require("tmai.util")
local u8 = require("tmai.u8")

local M = {}

local KEY = "tm-ark-7"   -- совпадает с XOR_KEY в tools/gen/gen_lore.py
local layers = {}       -- n -> { n, title, file, keys = {item=true} }
local epilogues = {}    -- "a"/"b"/"c" -> { key, file }
local key_of = {}       -- item -> layer n | "10a"...
local notes = {}        -- item -> { item, layer, title, file }
local state
local cache = {}

local function bxor(a, b)
  if bit32 then return bit32.bxor(a, b) end
  local r, p = 0, 1
  while a > 0 or b > 0 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a, b, p = (a - x) / 2, (b - y) / 2, p * 2
  end
  return r
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64I = {}
for i = 1, 64 do B64I[B64:sub(i, i)] = i - 1 end

local function b64decode(s)
  s = s:gsub("[^%w%+/=]", "")
  local out, n = {}, 0
  for i = 1, #s, 4 do
    local a, b, c, d = B64I[s:sub(i, i)], B64I[s:sub(i + 1, i + 1)], B64I[s:sub(i + 2, i + 2)], B64I[s:sub(i + 3, i + 3)]
    if not a or not b then break end
    local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
    n = n + 1; out[n] = string.char(math.floor(v / 65536) % 256)
    if c then n = n + 1; out[n] = string.char(math.floor(v / 256) % 256) end
    if d then n = n + 1; out[n] = string.char(v % 256) end
  end
  return table.concat(out)
end

function M.decode(data)
  local raw = b64decode(data)
  local out = {}
  for i = 1, #raw do
    out[i] = string.char(bxor(raw:byte(i), KEY:byte((i - 1) % #KEY + 1)))
    if i % 4096 == 0 then util.yield() end
  end
  return table.concat(out)
end

local function read_dat(file)
  if cache[file] then return cache[file] end
  local enc = util.read_file(util.ROM_DIR .. "/lore/" .. file .. ".dat")
  local text = enc and M.decode(enc) or ""
  cache[file] = text
  return text
end

local function section(text, name)
  return (text:match("##" .. name .. "\n(.-)\n##") or text:match("##" .. name .. "\n(.*)$") or ""):gsub("%s+$", "")
end

function M.init(st)
  state = st
  state.keys = state.keys or {}       -- item -> {t, by}
  state.notes = state.notes or {}     -- item -> {t, by}
  state.announced = state.announced or 0
  layers, epilogues, key_of, notes = {}, {}, {}, {}
  for _, row in ipairs(util.read_tsv(util.ROM_DIR .. "/lore/layers.tsv")) do
    local ep = row.layer:match("^10(%a)$")
    if ep then
      epilogues[ep] = { key = row.keys, file = row.file }
      key_of[row.keys] = "10" .. ep
    else
      local n = tonumber(row.layer)
      local L = { n = n, title = row.title, file = row.file, keys = {} }
      for k in (row.keys or ""):gmatch("[^,]+") do L.keys[k] = true; key_of[k] = n end
      layers[n] = L
    end
  end
  for _, row in ipairs(util.read_tsv(util.ROM_DIR .. "/lore/notes.tsv")) do
    row.layer = tonumber(row.layer) or 0
    notes[row.item] = row
  end
end

function M.is_interesting(item) return key_of[item] ~= nil or notes[item] ~= nil end

-- Восстановленный слой: максимальный L, такой что все слои 1..L открыты.
function M.level()
  local L = 0
  while layers[L + 1] do
    local open = false
    for k in pairs(layers[L + 1].keys) do if state.keys[k] then open = true end end
    if not open then break end
    L = L + 1
  end
  return L
end

-- Режим после финала: "a" | "b" | "c" | nil
function M.epilogue()
  for code, e in pairs(epilogues) do
    if state.keys[e.key] then return code end
  end
  return nil
end

-- Предмет побывал в Ящике памяти. Возвращает список событий:
--   { kind="layer", n=, title=, record= }  — снята печать со слоя (может быть несколько подряд)
--   { kind="note", item=, title=, text=, understood=bool }
--   { kind="epilogue", code= }
--   { kind="pending", item= }               — ключ «из будущего», ждёт предыдущие слои
function M.on_item(item, who)
  local events = {}
  local k = key_of[item]
  if k and not state.keys[item] then
    local before = M.level()
    state.keys[item] = { t = util.now(), by = who or "?" }
    if type(k) == "string" then
      events[#events + 1] = { kind = "epilogue", code = k:sub(3) }
    else
      local after = M.level()
      if after > before then
        for n = before + 1, after do
          local text = read_dat(layers[n].file)
          events[#events + 1] = { kind = "layer", n = n, title = layers[n].title, record = section(text, "RECORD") }
        end
      else
        events[#events + 1] = { kind = "pending", item = item }
      end
    end
  end
  local note = notes[item]
  if note and not state.notes[item] then
    state.notes[item] = { t = util.now(), by = who or "?" }
    local text = read_dat(note.file)
    events[#events + 1] = { kind = "note", item = item, title = note.title, text = text, understood = note.layer <= M.level() }
  end
  return events
end

-- Текст памяти для системного промпта: знания всех восстановленных слоёв + понятые находки (в бюджете байт).
function M.memory_digest(budget)
  local L = M.level()
  local parts, used = {}, 0
  local function add(s)
    if used + #s > budget then return false end
    parts[#parts + 1] = s; used = used + #s; return true
  end
  local ep = M.epilogue()
  if ep == "b" then
    return section(read_dat(epilogues.b.file), "MEMORY"), L
  end
  for n = 0, L do
    add("[слой " .. n .. " «" .. layers[n].title .. "»] " .. section(read_dat(layers[n].file), "MEMORY"))
  end
  if ep then add("[после] " .. section(read_dat(epilogues[ep].file), "MEMORY")) end
  local rows = {}
  for item in pairs(state.notes) do
    local row = notes[item]
    if row and row.layer <= L then rows[#rows + 1] = row end
  end
  table.sort(rows, function(a, b) if a.layer ~= b.layer then return a.layer < b.layer end return a.item < b.item end)
  local titles = {}
  for _, row in ipairs(rows) do titles[#titles + 1] = "«" .. row.title .. "»" end
  if #titles > 0 then
    add("Прочитанные находки экипажа (полный текст — инструмент memory_read): " .. table.concat(titles, ", ") .. ".")
  end
  return table.concat(parts, "\n"), L
end

-- Указания характера: стили всех открытых слоёв 0..L по порядку (поздние уточняют/отменяют ранние),
-- после финала — только стиль режима финала.
function M.style()
  local ep = M.epilogue()
  if ep then return section(read_dat(epilogues[ep].file), "STYLE") end
  local out = {}
  for n = 0, M.level() do
    local s = section(read_dat(layers[n].file), "STYLE")
    if s ~= "" then out[#out + 1] = s end
  end
  return table.concat(out, "\n")
end

function M.record(n)
  if not layers[n] then return nil end
  return section(read_dat(layers[n].file), "RECORD"), layers[n].title
end

function M.list()
  local L = M.level()
  local out = {}
  for item in pairs(state.notes) do
    local row = notes[item]
    if row then out[#out + 1] = { item = item, title = row.title, restored = row.layer <= L } end
  end
  table.sort(out, function(a, b) return a.title < b.title end)
  return out, L
end

function M.memory_read(item)
  local row = notes[item]
  if not row then
    for it, r in pairs(notes) do if u8.lower(r.title) == u8.lower(item or "") then row = r; item = it end end
  end
  if not row or not state.notes[item] then return nil, "запись не найдена" end
  if row.layer > M.level() then return "[фрагмент без контекста: сектор памяти, нужный для понимания, ещё опечатан]" end
  return u8.truncate(read_dat(row.file), 5000)
end

return M
