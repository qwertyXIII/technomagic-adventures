-- tmai.embed — векторный поиск по базе знаний (OpenAI-совместимый /v1/embeddings).
-- Векторы фрагментов считаются в игре (первый запуск/смена базы), кэш на диске компьютера:
--   /tmai/emb/index.json — { hash, model, dims, frags = { {kb, layer, off, scale}, ... } }
--   /tmai/emb/vectors.bin — int8-квантованные векторы подряд (dims байт на фрагмент).
-- Размер: N * dims байт (300 фрагментов * 512 = 150 КБ). Без параметра dimensions у
-- больших моделей (3072) — 0.9 МБ, поэтому computer_space_limit поднять до 8-16 МБ.

local json = require("tmai.json")
local util = require("tmai.util")

local M = {}

local DIR = util.DATA_DIR .. "/emb"
local cfg
local index, blob
M.state = "off"   -- off | building | ready | error
M.progress = ""

function M.configure(c) cfg = c end

function M.enabled()
  return cfg and cfg.emb_model ~= "" and cfg.emb_endpoint ~= "" and cfg.emb_key ~= ""
end

local function key() return cfg.emb_key end

-- FNV-1a 32 bit (хэш базы знаний + модели, чтобы понять, что кэш устарел)
function M.hash(str, h)
  h = h or 2166136261
  for i = 1, #str do
    h = bit32.bxor(h, str:byte(i))
    -- h * 16777619 mod 2^32 без потери точности double: 16777619 = 2^24 + 403
    h = ((h % 256) * 16777216 + h * 403) % 4294967296
    if i % 8192 == 0 then util.yield() end
  end
  return h
end

local function request(inputs)
  local body = { model = cfg.emb_model, input = inputs }
  if (cfg.emb_dims or 0) > 0 then body.dimensions = cfg.emb_dims end
  local res, err, fail = http.post({
    url = cfg.emb_endpoint, body = json.encode(body), binary = true, timeout = cfg.timeout,
    headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. key() },
  })
  if not res then
    local detail = tostring(err)
    if fail then detail = detail .. " " .. tostring(fail.readAll()):sub(1, 300); fail.close() end
    return nil, "embeddings: " .. detail
  end
  local text = res.readAll(); res.close()
  local data, jerr = json.decode(text)
  if not data or not data.data then return nil, "embeddings: bad response " .. tostring(jerr) end
  local out = {}
  for _, d in ipairs(data.data) do out[(d.index or #out) + 1] = d.embedding end
  return out
end

local function quantize(vec)
  local norm = 0
  for i = 1, #vec do norm = norm + vec[i] * vec[i] end
  norm = math.sqrt(norm)
  if norm == 0 then norm = 1 end
  local maxv = 0
  for i = 1, #vec do local a = math.abs(vec[i] / norm); if a > maxv then maxv = a end end
  local scale = maxv > 0 and maxv / 127 or 1
  local bytes = {}
  for i = 1, #vec do
    local q = math.floor(vec[i] / norm / scale + 0.5)
    if q > 127 then q = 127 elseif q < -127 then q = -127 end
    bytes[i] = string.char(q + 128)
  end
  return table.concat(bytes), scale
end

local function dot_q(qvec, off, dims, scale)
  local s = 0
  local step = 256
  for base = 0, dims - 1, step do
    local n = math.min(step, dims - base)
    local bytes = { blob:byte(off + base + 1, off + base + n) }
    for i = 1, n do s = s + qvec[base + i] * (bytes[i] - 128) end
  end
  return s * scale
end

-- Построить/загрузить кэш. fragments = { {kb=, layer=, text=}, ... }, kb_hash — хэш текстов.
function M.build(fragments, kb_hash)
  if not M.enabled() then M.state = "off"; return end
  local want_hash = M.hash(cfg.emb_model .. "|" .. tostring(cfg.emb_dims), kb_hash)
  index = util.load_json(DIR .. "/index.json", nil)
  if index and index.hash == want_hash and fs.exists(DIR .. "/vectors.bin") then
    blob = util.read_file(DIR .. "/vectors.bin")
    M.state = "ready"
    return
  end
  M.state = "building"
  local parts, frags, dims = {}, {}, nil
  local batch = 16
  for i = 1, #fragments, batch do
    local inputs = {}
    for j = i, math.min(i + batch - 1, #fragments) do inputs[#inputs + 1] = fragments[j].text end
    local vecs, err = request(inputs)
    if not vecs then M.state = "error"; M.progress = err; util.log("W", "%s", err); return end
    for k, vec in ipairs(vecs) do
      dims = dims or #vec
      local bytes, scale = quantize(vec)
      local f = fragments[i + k - 1]
      frags[#frags + 1] = { kb = f.kb, layer = f.layer, part = f.part, scale = scale }
      parts[#parts + 1] = bytes
    end
    M.progress = string.format("%d/%d", math.min(i + batch - 1, #fragments), #fragments)
    util.yield()
  end
  blob = table.concat(parts)
  index = { hash = want_hash, model = cfg.emb_model, dims = dims, frags = frags }
  if not fs.exists(DIR) then fs.makeDir(DIR) end
  util.write_file_atomic(DIR .. "/vectors.bin", blob)
  util.save_json(DIR .. "/index.json", index)
  M.state = "ready"
  util.log("I", "embeddings built: %d fragments, %d dims", #frags, dims or 0)
end

-- Векторный поиск: { {kb=, part=, layer=, score=}, ... } по убыванию близости.
function M.search(query, max_layer, limit)
  if M.state ~= "ready" then return nil end
  local vecs, err = request({ query })
  if not vecs then util.log("W", "%s", tostring(err)); return nil end
  local q = vecs[1]
  local norm = 0
  for i = 1, #q do norm = norm + q[i] * q[i] end
  norm = math.sqrt(norm); if norm == 0 then norm = 1 end
  for i = 1, #q do q[i] = q[i] / norm end
  local dims = index.dims
  local res = {}
  for n, f in ipairs(index.frags) do
    if f.layer <= max_layer then
      res[#res + 1] = { kb = f.kb, part = f.part, layer = f.layer, score = dot_q(q, (n - 1) * dims, dims, f.scale) }
    end
    if n % 40 == 0 then util.yield() end
  end
  table.sort(res, function(a, b) return a.score > b.score end)
  local out = {}
  for i = 1, math.min(limit or 6, #res) do out[i] = res[i] end
  return out
end

return M
