-- tmai.kb — база знаний (справочник по модам, сборке, миру) с гибридным поиском.
-- Файлы: /rom/tmai/kb/index.tsv  (id, layer, title, keywords, file)
--        /rom/tmai/kb/<file>      (markdown-текст раздела, 1-6 КБ)
-- layer — минимальный восстановленный слой памяти, с которого раздел виден ИИ (0 = сразу).
-- Поиск: если настроены эмбеддинги (tmai.embed) — косинус по фрагментам ~800 байт,
-- плюс ключевые слова; иначе только ключевые слова (стемы по 5 символов, фразы).
-- В промпт идут только лучшие фрагменты в пределах бюджета байт; остальное ИИ
-- может дочитать инструментами kb_search/kb_read.

local u8 = require("tmai.u8")
local util = require("tmai.util")
local embed = require("tmai.embed")

local M = {}

local entries          -- { id, layer, title, file, kw={}, tw={}, phrases={} }
local by_id = {}
local frag_cache = {}  -- id -> { part texts }

local FRAG = 800

local function load()
  if entries then return end
  entries = {}
  for _, row in ipairs(util.read_tsv(util.ROM_DIR .. "/kb/index.tsv")) do
    local e = { id = row.id, layer = tonumber(row.layer) or 0, title = row.title, file = row.file,
      kw = {}, tw = {}, phrases = {} }
    for raw in (row.keywords or ""):gmatch("[^,]+") do
      local phrase = u8.lower(u8.trim(raw))
      if #phrase > 0 then e.phrases[#e.phrases + 1] = phrase end
      for _, s in ipairs(u8.tokens(phrase, 2)) do e.kw[s] = true end
    end
    for _, s in ipairs(u8.tokens(row.title or "", 3)) do e.tw[s] = true end
    entries[#entries + 1] = e
    by_id[e.id] = e
  end
end

function M.count() load(); return #entries end

local function read_text(e)
  return util.read_file(util.ROM_DIR .. "/kb/" .. e.file) or ""
end

local function parts_of(e)
  if frag_cache[e.id] then return frag_cache[e.id] end
  local parts = u8.chunks(read_text(e), FRAG)
  frag_cache[e.id] = parts
  return parts
end

-- Все фрагменты (для построения векторов) и хэш базы.
function M.fragments()
  load()
  local out, h = {}, nil
  for _, e in ipairs(entries) do
    local parts = parts_of(e)
    for i, p in ipairs(parts) do
      out[#out + 1] = { kb = e.id, part = i, layer = e.layer, text = e.title .. "\n" .. p }
      h = embed.hash(p, h)
    end
    util.yield()
  end
  return out, h or 0
end

-- Поиск по ключевым словам: { {entry=, score=}, ... }
function M.search(query, max_layer, limit)
  load()
  max_layer = max_layer or 0
  local q = u8.lower(query)
  local qt = u8.tokens(query, 2)
  local scored = {}
  for i, e in ipairs(entries) do
    if e.layer <= max_layer then
      local s = 0
      for _, t in ipairs(qt) do
        if e.kw[t] then s = s + 3 end
        if e.tw[t] then s = s + 2 end
      end
      for _, p in ipairs(e.phrases) do
        if #p >= 4 and q:find(p, 1, true) then s = s + 4 end
      end
      if s > 0 then scored[#scored + 1] = { entry = e, score = s } end
    end
    if i % 200 == 0 then util.yield() end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  local res = {}
  for i = 1, math.min(limit or 5, #scored) do res[i] = scored[i] end
  return res
end

-- Справка для промпта в пределах бюджета байт. Возвращает текст и список id.
function M.context_for(query, max_layer, budget)
  load()
  local blocks, used, seen, ids = {}, 0, {}, {}
  local function add(title, id, text)
    local block = "### " .. title .. " [" .. id .. "]\n" .. text
    if used + #block > budget then
      local room = budget - used
      if room < 500 then return false end
      block = u8.truncate(block, room)
    end
    blocks[#blocks + 1] = block
    used = used + #block
    ids[#ids + 1] = id
    return true
  end
  -- 1) векторные фрагменты
  local vhits = embed.search(query, max_layer, 6)
  if vhits then
    for _, h in ipairs(vhits) do
      if h.score < 0.25 then break end
      local e = by_id[h.kb]
      local key = h.kb .. "#" .. h.part
      if e and not seen[key] then
        seen[key] = true
        local p = parts_of(e)[h.part]
        if p and not add(e.title, e.id, p) then break end
      end
    end
  end
  -- 2) ключевые слова: раздел целиком (если сильное совпадение) или его начало
  for _, h in ipairs(M.search(query, max_layer, 3)) do
    if h.score < 3 then break end
    if not seen[h.entry.id .. "#1"] then
      seen[h.entry.id .. "#1"] = true
      if not add(h.entry.title, h.entry.id, read_text(h.entry)) then break end
    end
  end
  return table.concat(blocks, "\n\n"), ids
end

-- Для инструментов
function M.tool_search(query, max_layer)
  local out = {}
  for _, h in ipairs(M.search(query, max_layer, 8)) do
    out[#out + 1] = { id = h.entry.id, title = h.entry.title }
  end
  local vhits = embed.search(query, max_layer, 5)
  for _, h in ipairs(vhits or {}) do
    local e = by_id[h.kb]
    if e then out[#out + 1] = { id = e.id, title = e.title, similarity = math.floor(h.score * 100) / 100 } end
  end
  return out
end

function M.tool_read(id, max_layer)
  load()
  local e = by_id[id]
  if not e or e.layer > (max_layer or 0) then return nil, "нет такого раздела" end
  return u8.truncate(read_text(e), 6000)
end

return M
