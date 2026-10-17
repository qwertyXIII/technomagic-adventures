-- tmrelay — вышка-ретранслятор связи с ЛОЦМАНом (компьютер с беспроводным или эндер-модемом, метка TM-RELAY…).
--  1) Пересылает все rednet-сообщения (стандартный `repeat`) — продлевает связь КПК и других вышек.
--  2) Раз в минуту сообщает капсуле, что жива (протокол tmai_relay) — ЛОЦМАН знает, какие вышки на связи.
-- Установка: поставьте компьютер повыше (дальность радио растёт с высотой), прикрепите модем,
-- `label set TM-RELAY-1`, `reboot`, введите ник и стойте рядом (до 4 блоков) — капсула сама найдёт вышку
-- и измерит её радио. Вышка должна быть в зоне связи капсулы или другой вышки.
local util = require("tmai.util")
local cc = require("tmai.text").cc
local STATE = "/tmrelay.json"
local st = util.load_json(STATE, {})

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError(cc("Нужен беспроводной или эндер-модем")); return end
for _, n in ipairs(peripheral.getNames()) do if peripheral.hasType(n, "modem") then rednet.open(n) end end

term.clear(); term.setCursorPos(1, 1)
print(cc("Вышка связи TM-RELAY #" .. os.getComputerID()))
if not st.ok then
  write(cc("Ваш ник (стойте рядом с вышкой): "))
  local nick = read()
  print(cc("Связываюсь с капсулой..."))
  rednet.broadcast({ op = "setup", player = nick }, "tmai_relay_setup")
  local _, msg = rednet.receive("tmai_relay_setup", 30)
  if not msg then printError(cc("Нет ответа: вышка вне зоны радио капсулы (поставьте выше или ближе).")); return end
  if msg.op ~= "relay_ok" then printError(cc("Капсула: " .. tostring(msg.error))); return end
  st = { ok = true, info = msg.info }
  util.save_json(STATE, st)
end
local i = st.info or {}
print(cc(("Вышка: %s %s %s, %s"):format(tostring(i.x), tostring(i.y), tostring(i.z), i.ender and "эндер-модем (без ограничений)" or ("дальность " .. tostring(i.range)))))
print(cc("Перерегистрация: удалить /tmrelay.json и reboot."))

local function beacon()
  while true do
    rednet.broadcast({ op = "relay_hb" }, "tmai_relay")
    sleep(60)
  end
end
parallel.waitForAny(beacon, function() shell.run("repeat") end)
