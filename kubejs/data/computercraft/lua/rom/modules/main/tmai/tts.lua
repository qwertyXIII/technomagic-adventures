-- tmai.tts — необязательная озвучка ответов (tmai.tts = true).
-- Провайдер: OpenAI-совместимый POST {tts_base_url}/audio/speech (OpenRouter: /api/v1/audio/speech),
-- {model, input, voice?, response_format="pcm"} -> сырые байты PCM (без JSON).
-- MP3 в Lua декодировать нереально — просим только "pcm" (у fish-audio на OpenRouter это и так формат по умолчанию).
-- Ожидается 16 бит signed little-endian, моно, частота tmai.tts_rate (Fish Audio по умолчанию 44100 Гц;
-- если голос «бурундук»/«замедленный» — поправить tts_rate). Если пришёл WAV (RIFF) — параметры из заголовка.
-- Голос: tmai.tts_voice — ID голоса из библиотеки Fish Audio (адрес fish.audio/m/<ID>); без него модель
-- каждый раз берёт случайный голос.
--
-- Скорость: текст режется на куски по предложениям (первый — короткий, чтобы звук начался быстрее), куски
-- запрашиваются параллельно (tmai.tts_parallel запросов сразу), играются строго по порядку, как только готов
-- очередной. Код (```…```) не читается. Озвучка идёт в своей корутине (M.loop): ЛОЦМАН не ждёт, пока договорит.
-- Параллельные запросы различаются по адресу (?part=…): обёртка http.post в CC ждёт ответ по URL.
-- Колонка CC: speaker.playAudio принимает таблицу int8 (-128..127) 48 кГц; при полном буфере возвращает false ->
-- ждём "speaker_audio_empty". Каждый кусок — с yield (лимит «too long without yielding»).
-- КПК с динамиком: куски отправляются по rednet (протокол tmai_radio, op="audio"), КПК играет их сам.
-- Любая ошибка озвучки пишется в лог и не мешает текстовому ответу.

local json = require("tmai.json")
local util = require("tmai.util")
local u8 = require("tmai.u8")

local M = {}
local cfg
local queue = {}         -- фразы на озвучку: { text, pda }
local MAX_QUEUE = 4
local seq_id = 0

function M.configure(c) cfg = c end

function M.enabled()
  return cfg and cfg.tts and cfg.tts_endpoint ~= "" and cfg.tts_model ~= "" and cfg.tts_key ~= ""
end

-- ---------- текст -> куски ----------
local function clean(text)
  text = tostring(text or "")
  text = text:gsub("```.-```", " (код — на экране) ")
  text = u8.clean_for_chat(text)
  text = text:gsub("https?://%S+", "ссылка")
  text = text:gsub("\226\128\166", "...")          -- …
  text = text:gsub("\194\171", "\""):gsub("\194\187", "\"")   -- « »
  text = text:gsub("[%*_#>|]", " ")
  return text
end

-- Предложения: конец — . ! ? (с кавычкой/скобкой) и пробел, или перевод строки.
local function sentences(s)
  local out, pos = {}, 1
  while pos <= #s do
    local a, b = s:find("[%.!%?]+[\"%)]*%s+", pos)
    local nl = s:find("\n", pos, true)
    if nl and (not a or nl < a) then a, b = nl, nl end
    local piece
    if a then piece = s:sub(pos, b); pos = b + 1 else piece = s:sub(pos); pos = #s + 1 end
    piece = piece:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if piece ~= "" and piece:find("[%w\128-\255]") then out[#out + 1] = piece end
  end
  return out
end

-- Слишком длинное предложение — по запятым/пробелам (байты ASCII, UTF-8 не рвётся).
local function split_long(s, max)
  local out = {}
  while u8.len(s) > max do
    local limit = u8.truncate(s, max * 2)          -- ~max символов кириллицы
    if #limit >= #s then break end
    local cut = limit:match("^.*()[,;:]%s") or limit:match("^.*()%s")
    if not cut or cut < #limit * 0.4 then cut = #limit end
    out[#out + 1] = s:sub(1, cut):match("^%s*(.-)%s*$")
    s = s:sub(cut + 1)
  end
  if s:match("%S") then out[#out + 1] = s:match("^%s*(.-)%s*$") end
  return out
end

-- Куски для запросов: первый — одно предложение (с короткими соседями), дальше — до max символов.
function M.split(text, max_total)
  local s = clean(text)
  if max_total and max_total > 0 and u8.len(s) > max_total then
    s = u8.truncate(s, max_total * 2)
    local cut = s:match("^.*()[%.!%?]")
    if cut and cut > #s * 0.5 then s = s:sub(1, cut) end
  end
  local sents = {}
  for _, snt in ipairs(sentences(s)) do
    for _, part in ipairs(split_long(snt, 240)) do sents[#sents + 1] = part end
  end
  local chunks, cur = {}, ""
  local function flush() if cur ~= "" then chunks[#chunks + 1] = cur; cur = "" end end
  for _, snt in ipairs(sents) do
    local limit = #chunks == 0 and 60 or 260
    if cur ~= "" and u8.len(cur) + 1 + u8.len(snt) > limit then flush() end
    cur = cur == "" and snt or (cur .. " " .. snt)
    if #chunks == 0 and u8.len(cur) >= 25 then flush() end      -- первый кусок — сразу
  end
  flush()
  return chunks
end

-- ---------- запрос и звук ----------
local function fetch(text, part)
  local body = { model = cfg.tts_model, input = text, response_format = "pcm" }
  if (cfg.tts_voice or "") ~= "" then body.voice = cfg.tts_voice end
  seq_id = seq_id + 1
  local url = cfg.tts_endpoint .. (cfg.tts_endpoint:find("?", 1, true) and "&" or "?") .. "part=" .. seq_id
  local tries = math.max(0, tonumber(cfg.retries) or 2)
  for attempt = 0, tries do
    local res, err, fail = http.post({
      url = url, body = json.encode(body), binary = true, timeout = cfg.timeout,
      headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. cfg.tts_key },
    })
    if res then
      local data = res.readAll()
      res.close()
      return data
    end
    local code = fail and fail.getResponseCode and fail.getResponseCode() or 0
    local detail = tostring(err)
    if fail then detail = detail .. " " .. tostring(fail.readAll()):sub(1, 200); fail.close() end
    if attempt >= tries or not (code == 429 or code >= 500) then return nil, detail end
    sleep(2 * (attempt + 1))
  end
end

local function parse_wav(data)
  if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return nil end
  local pos = 13
  local rate, channels, bits
  while pos + 8 <= #data do
    local id = data:sub(pos, pos + 3)
    local size = string.unpack("<I4", data, pos + 4)
    if id == "fmt " then
      channels, rate = string.unpack("<I2", data, pos + 10), string.unpack("<I4", data, pos + 12)
      bits = string.unpack("<I2", data, pos + 22)
    elseif id == "data" then
      return data:sub(pos + 8, pos + 7 + size), rate, channels, bits
    end
    pos = pos + 8 + size + (size % 2)
  end
  return nil
end

-- PCM16 LE -> куски int8 48 кГц; on_chunk(table) вызывается для каждого куска.
local function convert(data, rate, channels, on_chunk)
  local in_bytes = 2 * channels
  local total_in = math.floor(#data / in_bytes)
  local ratio = rate / 48000
  local out_total = math.floor(total_in / ratio)
  local CH = 16 * 1024
  local o = 0
  while o < out_total do
    local chunk = {}
    local n = math.min(CH, out_total - o)
    for k = 1, n do
      local pos = math.floor((o + k - 1) * ratio) * in_bytes + 1
      local lo, hi = data:byte(pos, pos + 1)
      local v = (hi or 0) * 256 + (lo or 0)
      if v >= 32768 then v = v - 65536 end
      v = math.floor(v / 256)
      if v > 127 then v = 127 elseif v < -128 then v = -128 end
      chunk[k] = v
    end
    o = o + n
    on_chunk(chunk)
    util.yield()
  end
end

local function to_string(chunk)
  local b = {}
  for i = 1, #chunk do b[i] = string.char(chunk[i] + 128) end
  return table.concat(b)
end

-- Сыграть один готовый ответ провайдера (колонка и/или КПК); seq — сквозной номер куска для КПК.
local function play(data, speaker, pda_id, seq)
  local rate, channels, bits = cfg.tts_rate, 1, 16
  local pcm, wr, wc, wb = parse_wav(data)
  if pcm then data, rate, channels, bits = pcm, wr, wc, wb end
  if bits ~= 16 then error("unsupported bits " .. tostring(bits), 0) end
  convert(data, rate, channels, function(chunk)
    seq[1] = seq[1] + 1
    if pda_id then rednet.send(pda_id, { op = "audio", seq = seq[1], data = to_string(chunk) }, "tmai_radio") end
    if speaker then
      while not speaker.playAudio(chunk, cfg.tts_volume) do os.pullEvent("speaker_audio_empty") end
    end
  end)
end

-- Озвучить одну фразу целиком: куски запрашиваются параллельно, играются по порядку.
local function speak_now(text, pda_id)
  local speaker = peripheral.find("speaker")
  if not speaker and not pda_id then return end
  local chunks = M.split(text, tonumber(cfg.tts_max_chars) or 0)
  if #chunks == 0 then return end
  local results = {}            -- [i] = данные | { err = … }
  local next_i, played = 1, 0
  local AHEAD = 4               -- не держать в памяти больше 4 готовых кусков впереди
  local function fetcher()
    while true do
      while next_i <= #chunks and next_i > played + AHEAD do os.pullEvent("tmai_tts") end
      if next_i > #chunks then return end
      local i = next_i
      next_i = next_i + 1
      local data, err = fetch(chunks[i], i)
      results[i] = data or { err = err or "нет ответа" }
      os.queueEvent("tmai_tts")
    end
  end
  local function player()
    local seq = { 0 }
    for i = 1, #chunks do
      while results[i] == nil do os.pullEvent("tmai_tts") end
      local r = results[i]
      results[i] = nil
      if type(r) == "table" then
        util.log("W", "tts part %d/%d: %s", i, #chunks, tostring(r.err))
      else
        local ok, perr = pcall(play, r, speaker, pda_id, seq)
        if not ok then util.log("W", "tts play: %s", tostring(perr)) end
      end
      played = i
      os.queueEvent("tmai_tts")
    end
  end
  local workers = { player }
  for _ = 1, math.max(1, math.min(6, tonumber(cfg.tts_parallel) or 3)) do workers[#workers + 1] = fetcher end
  parallel.waitForAll(table.unpack(workers))
end

-- Поставить фразу в очередь озвучки (не ждёт). pda_id — дополнительно отправить звук на КПК.
function M.speak(text, pda_id)
  if not M.enabled() then return false end
  if not peripheral.find("speaker") and not pda_id then return false end
  if #queue >= MAX_QUEUE then table.remove(queue, 1) end   -- отстали — старое не договариваем
  queue[#queue + 1] = { text = text, pda = pda_id }
  os.queueEvent("tmai_tts_queue")
  return true
end

-- Корутина озвучки (запускает app.lua в parallel).
function M.loop()
  while true do
    while #queue == 0 do os.pullEvent("tmai_tts_queue") end
    local job = table.remove(queue, 1)
    local ok, err = pcall(speak_now, job.text, job.pda)
    if not ok then util.log("W", "tts: %s", tostring(err)) end
  end
end

return M
