-- tmai.tts — необязательная озвучка ответов (tmai.tts = true).
-- Провайдер: OpenAI-совместимый POST {tts_base_url}/audio/speech (OpenRouter: /api/v1/audio/speech),
-- {model, input, voice?, response_format="pcm"} -> сырые байты PCM (без JSON).
-- MP3 в Lua декодировать нереально — просим только "pcm" (у fish-audio на OpenRouter это и так формат по умолчанию).
-- Ожидается 16 бит signed little-endian, моно, частота tmai.tts_rate (Fish Audio по умолчанию 44100 Гц;
-- если голос «бурундук»/«замедленный» — поправить tts_rate). Если пришёл WAV (RIFF) — параметры из заголовка.
-- Колонка CC: speaker.playAudio принимает таблицу int8 (-128..127) 48 кГц; при полном буфере возвращает false ->
-- ждём "speaker_audio_empty". Каждый кусок — с yield (лимит «too long without yielding»).
-- КПК с динамиком: куски отправляются по rednet (протокол tmai_radio, op="audio"), КПК играет их сам.
-- Любая ошибка озвучки пишется в лог и не мешает текстовому ответу.

local json = require("tmai.json")
local util = require("tmai.util")
local u8 = require("tmai.u8")

local M = {}
local cfg

function M.configure(c) cfg = c end

function M.enabled()
  return cfg and cfg.tts and cfg.tts_endpoint ~= "" and cfg.tts_model ~= "" and cfg.tts_key ~= ""
end

local function first_paragraph(text, max_chars)
  text = u8.clean_for_chat(text)
  local p = text:match("^(.-)\n\n") or text
  if u8.len(p) > max_chars then
    local ok, off = pcall(utf8.offset, p, max_chars + 1)
    if ok and off then p = p:sub(1, off - 1) end
    local cut = p:match("^.*()[%.!%?]")
    if cut and cut > #p * 0.5 then p = p:sub(1, cut) end
  end
  return p
end

local function fetch(text)
  local body = { model = cfg.tts_model, input = text, response_format = "pcm" }
  if cfg.tts_voice ~= "" then body.voice = cfg.tts_voice end
  local res, err, fail = http.post({
    url = cfg.tts_endpoint, body = json.encode(body), binary = true, timeout = cfg.timeout,
    headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. cfg.tts_key },
  })
  if not res then
    local detail = tostring(err)
    if fail then detail = detail .. " " .. tostring(fail.readAll()):sub(1, 200); fail.close() end
    return nil, detail
  end
  local data = res.readAll()
  res.close()
  return data
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

-- Озвучить текст на колонке капсулы; pda_id — дополнительно отправить звук на КПК.
function M.speak(text, pda_id)
  if not M.enabled() then return false end
  local speaker = peripheral.find("speaker")
  if not speaker and not pda_id then return false end
  local ok, err = pcall(function()
    local phrase = first_paragraph(text, cfg.tts_max_chars)
    if phrase == "" then return end
    local data, ferr = fetch(phrase)
    if not data then error(ferr, 0) end
    local rate, channels, bits = cfg.tts_rate, 1, 16
    local pcm, wr, wc, wb = parse_wav(data)
    if pcm then data, rate, channels, bits = pcm, wr, wc, wb end
    if bits ~= 16 then error("unsupported bits " .. tostring(bits), 0) end
    local seq = 0
    convert(data, rate, channels, function(chunk)
      seq = seq + 1
      if pda_id then rednet.send(pda_id, { op = "audio", seq = seq, data = to_string(chunk) }, "tmai_radio") end
      if speaker then
        while not speaker.playAudio(chunk, cfg.tts_volume) do os.pullEvent("speaker_audio_empty") end
      end
    end)
  end)
  if not ok then util.log("W", "tts: %s", tostring(err)) end
  return ok
end

return M
