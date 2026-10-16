-- tmrelay — вышка-ретранслятор связи с ЛОЦМАНом (компьютер с беспроводным или эндер-модемом, метка TM-RELAY…).
--  1) Пересылает все rednet-сообщения (стандартный `repeat`) — продлевает связь КПК и других вышек.
--  2) Раз в минуту сообщает капсуле, что жива (протокол tmai_relay) — по живым вышкам ЛОЦМАН решает,
--     в зоне ли связи игрок, который пишет в обычный чат.
-- Установка: поставьте компьютер повыше (дальность радио растёт с высотой), прикрепите модем,
-- `label set TM-RELAY-1`, `reboot`, введите ник и стойте рядом (до 4 блоков) — капсула сама найдёт вышку
-- и измерит её радио. Вышка должна быть в зоне связи капсулы или другой вышки.
local util = require("tmai.util")
local STATE = "/tmrelay.json"
local st = util.load_json(STATE, {})

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("Need a wireless or ender modem"); return end
for _, n in ipairs(peripheral.getNames()) do if peripheral.hasType(n, "modem") then rednet.open(n) end end

term.clear(); term.setCursorPos(1, 1)
print("TM-RELAY #" .. os.getComputerID())
if not st.ok then
  write("Your nickname (stand next to the relay): ")
  local nick = read()
  print("Contacting the capsule...")
  rednet.broadcast({ op = "setup", player = nick }, "tmai_relay_setup")
  local _, msg = rednet.receive("tmai_relay_setup", 30)
  if not msg then printError("No answer: the relay is out of radio range of the capsule (build it higher or closer)."); return end
  if msg.op ~= "relay_ok" then printError("Capsule: " .. tostring(msg.error)); return end
  st = { ok = true, info = msg.info }
  util.save_json(STATE, st)
end
local i = st.info or {}
print(("Relay at %s %s %s, %s"):format(tostring(i.x), tostring(i.y), tostring(i.z), i.ender and "ender (unlimited)" or ("range " .. tostring(i.range))))
print("Delete /tmrelay.json and reboot to re-register.")

local function beacon()
  while true do
    rednet.broadcast({ op = "relay_hb" }, "tmai_relay")
    sleep(60)
  end
end
parallel.waitForAny(beacon, function() shell.run("repeat") end)
