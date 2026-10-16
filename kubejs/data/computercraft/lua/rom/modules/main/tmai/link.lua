-- tmai.link — проводной канал «ИИ <-> навигационно-связной модуль» (командный компьютер TM-NAV).
-- Используются «сырые» modem-сообщения на канале CH по ПРОВОДНОМУ модему. TM-NAV принимает
-- привилегированные операции, только если сообщение пришло на его проводной модем (поле side
-- события modem_message). ВНИМАНИЕ: distance у проводных сообщений НЕ nil, а длина пути по
-- кабелю (WiredNetworkImpl.transmitPacket) — по distance провод от радио не отличить.
-- Беспроводные клиенты (КПК, ретрансляторы) идут через rednet-протокол RADIO, их TM-NAV
-- лишь пересылает ИИ как обычные вопросы.

local util = require("tmai.util")

local M = {}

M.CH = 7300            -- проводной канал ИИ<->NAV
M.RADIO = "tmai_radio" -- rednet-протокол КПК/ретрансляторов

local modem, modem_name
local replies = {}     -- id -> msg

-- Найти проводной модем (isWireless() == false).
function M.attach()
  modem, modem_name = nil, nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then
      local p = peripheral.wrap(name)
      if not p.isWireless() then modem, modem_name = p, name; break end
    end
  end
  if modem then modem.open(M.CH) end
  return modem ~= nil
end

-- Вызывается слушателем событий для каждого modem_message.
-- Возвращает true, если это ответ на наш запрос.
function M.on_modem_message(side, channel, reply_ch, msg, distance)
  if channel ~= M.CH or side ~= modem_name or type(msg) ~= "table" then return false end
  if msg.re and msg.from == "nav" then
    replies[msg.re] = msg
    os.queueEvent("tmai_link_reply", msg.re)
    return true
  end
  return false
end

-- Синхронный запрос к TM-NAV (вызывать из рабочей корутины).
function M.call(op, args, timeout)
  if not modem and not M.attach() then return nil, "нет связи с навигационным модулем" end
  local id = tostring(os.epoch("utc")) .. tostring(math.random(1000, 9999))
  local msg = args and util.copy(args) or {}
  msg.op, msg.id, msg.from = op, id, "ai"
  msg.ai_id = os.getComputerID()
  modem.transmit(M.CH, M.CH, msg)
  local timer = os.startTimer(timeout or 5)
  while true do
    local ev, a = os.pullEvent()
    if ev == "tmai_link_reply" and a == id then
      local r = replies[id]; replies[id] = nil
      os.cancelTimer(timer)
      if r.ok then return r.data or {} end
      return nil, r.error or "ошибка модуля"
    elseif ev == "timer" and a == timer then
      return nil, "навигационный модуль не ответил"
    end
  end
end

return M
