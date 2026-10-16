-- tmai.link — канал «ИИ <-> штурманский модуль» (командный компьютер TM-NAV, программа tmnav).
--
-- Пакеты ходят «сырыми» modem-сообщениями на канале CH сразу по ВСЕМ модемам компьютера: проводная сеть
-- (вплотную через модем или по кабелю через полбазы), беспроводной модем (в пределах его дальности) или
-- эндер-модем (без границ). Поэтому после переезда ИИ сам находит модуль, где бы тот ни стоял.
--
-- Подлинность проверяется не типом модема, а подписью HMAC-SHA256 общим ключом (tmai.sha256):
--   * ключ модуль выдаёт при спаривании: первое знакомство по проводу (капсула) или компьютер ИИ стоит
--     вплотную к модулю (повторное спаривание, если ключ потерян);
--   * ключ лежит только на дисках двух компьютеров (/tmai/link.json и /tmnav/state.json);
--   * запрос: { from="ai", ai_id, p=<JSON {op,id,t,args…}>, mac=HMAC(key, "ai|"..p) };
--     ответ:  { from="nav", re=id, p=<JSON {ok,data,error}>, mac=HMAC(key, "nav|"..re.."|"..p) };
--   * t — время (мс) + строго растущий счётчик: модуль не принимает старые и повторённые пакеты.
-- Так чужая программа в сети (в том числе написанная нейросетью через tmexec) не может ни подделать
-- запрос к командному компьютеру, ни повторить перехваченный. Нейросеть ключа не видит.
-- Беспроводные клиенты (КПК, ретрансляторы) идут отдельно — rednet-протоколом RADIO.

local util = require("tmai.util")
local json = require("tmai.json")
local sha = require("tmai.sha256")

local M = {}

M.CH = 7300            -- канал ИИ<->NAV
M.RADIO = "tmai_radio" -- rednet-протокол КПК/ретрансляторов

local KEY_PATH = util.DATA_DIR .. "/link.json"
local PAIR_RETRY = 30  -- с: не чаще одной попытки спаривания

local modems = {}      -- имена всех модемов компьютера
local replies = {}     -- id -> { ok, data, error, code, key }
local link = nil       -- { key, nav } с диска
local last_t = 0
local last_pair_try = -PAIR_RETRY

local function load_key()
  if link == nil then link = util.load_json(KEY_PATH, {}) end
  return link.key
end

-- Открыть канал на всех модемах (проводных и беспроводных). Вызывается при старте и при смене периферии.
function M.attach()
  modems = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then
      modems[#modems + 1] = name
      pcall(peripheral.call, name, "open", M.CH)
    end
  end
  return #modems > 0
end

local function transmit(msg)
  for _, name in ipairs(modems) do pcall(peripheral.call, name, "transmit", M.CH, M.CH, msg) end
end

-- Вызывается слушателем событий для каждого modem_message. Возвращает true, если это ответ модуля.
function M.on_modem_message(side, channel, reply_ch, msg, distance)
  if channel ~= M.CH or type(msg) ~= "table" or msg.from ~= "nav" or type(msg.re) ~= "string" then return false end
  local r
  if type(msg.p) == "string" and type(msg.mac) == "string" then
    local key = load_key()
    if not key or sha.hmac(key, "nav|" .. msg.re .. "|" .. msg.p) ~= msg.mac then return false end  -- чужая подпись
    r = json.decode(msg.p)
    if type(r) ~= "table" then return false end
  else
    -- неподписанный ответ: только отказ (или выдача ключа на наш запрос спаривания) — успехом не считается
    r = { ok = false, error = msg.error, code = msg.code, key = msg.key, nav = msg.nav_id }
  end
  replies[msg.re] = r
  os.queueEvent("tmai_link_reply", msg.re)
  return true
end

local function wait_reply(id, timeout)
  local timer = os.startTimer(timeout)
  while true do
    local ev, a = os.pullEvent()
    if ev == "tmai_link_reply" and a == id then
      os.cancelTimer(timer)
      local r = replies[id]; replies[id] = nil
      return r
    elseif ev == "timer" and a == timer then
      replies[id] = nil
      return nil
    end
  end
end

local function next_id()
  last_t = math.max(os.epoch("utc"), last_t + 1)
  return last_t, ("%d-%d"):format(os.getComputerID(), last_t)
end

-- Спаривание: модуль выдаёт ключ, если это первое знакомство по проводу или компьютер ИИ стоит вплотную к нему.
local function pair()
  if util.now() - last_pair_try < PAIR_RETRY then return nil, "штурманский модуль не спарен с этим компьютером" end
  last_pair_try = util.now()
  local _, id = next_id()
  transmit({ from = "ai", op = "pair", id = id, ai_id = os.getComputerID() })
  local r = wait_reply(id, 5)
  if not r then return nil, "навигационный модуль не ответил" end
  if type(r.key) ~= "string" or #r.key < 32 then
    util.log("W", "link: pairing refused: %s", tostring(r.error))
    return nil, r.error or "модуль отказал в спаривании"
  end
  link = { key = r.key, nav = r.nav }
  util.save_json(KEY_PATH, link)
  util.log("I", "link: paired with NAV #%s", tostring(r.nav))
  return true
end

-- Синхронный запрос к TM-NAV (вызывать из рабочей корутины). Возвращает data или nil, ошибка.
function M.call(op, args, timeout)
  if #modems == 0 and not M.attach() then return nil, "нет связи с навигационным модулем (нет модема)" end
  if not load_key() then
    local ok, err = pair()
    if not ok then return nil, err end
  end
  local t, id = next_id()
  local body = args and util.copy(args) or {}
  body.op, body.id, body.t = op, id, t
  local p = json.encode(body)
  transmit({ from = "ai", ai_id = os.getComputerID(), p = p, mac = sha.hmac(link.key, "ai|" .. p) })
  local r = wait_reply(id, timeout or 5)
  if not r then return nil, "навигационный модуль не ответил" end
  if r.ok then return r.data or {} end
  if r.code == "unpaired" then
    -- модуль нас не знает (его ключ потерян или он спарен с другим компьютером). Старый ключ не стираем:
    -- такой ответ без подписи мог прислать кто угодно. Пробуем спариться заново (выйдет, если это первое
    -- знакомство по проводу или компьютер ИИ стоит вплотную к модулю); удачная попытка заменит ключ.
    util.log("W", "link: NAV says unpaired")
    pair()
  end
  return nil, r.error or "ошибка модуля"
end

return M
