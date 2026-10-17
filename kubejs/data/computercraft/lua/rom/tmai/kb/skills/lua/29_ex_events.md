Связь программы tmexec со «Сценариями» ЛОЦМАНа — rednet-протокол "tmai_event" (единственный tmai_*, который можно программам). Сообщение — таблица { name = "lockdown", data = … } (name — латиница, цифры, _ . -; data — строка, число или true/false).
- ЛОЦМАН → программам: действие сценария { type = "event", name = "lockdown" } шлёт всем (broadcast) или одному (to = id). Свои сообщения ЛОЦМАН помечает from = "locman". Проверяй отправителя: id ЛОЦМАНа записан агентом в settings.get("tmexec.owner").
- Программа → ЛОЦМАНу: rednet.send(owner, { name = "door_button", data = … }, "tmai_event"). Сценарий с when { type = "event", name = "door_button" } (можно from = id программы) сработает без нейросети.
- Принимать — в общем цикле os.pullEvent(): событие rednet_message(id, msg, proto) с proto == "tmai_event". rednet.receive(PROTO) тоже годится, если больше ждать нечего.
- Одна программа = один компьютер с tmexec (новый запуск останавливает прежнюю). Новую программу ставь на свободный компьютер (computers_list: free = true). Свободного нет — попроси игрока поставить ещё компьютер (или черепашку) с проводным или беспроводным модемом и ввести «tmexec startup», метку — по желанию («label set Двери»). Работающую программу без согласия игрока не вытесняй.
- Простое «по событию переключить выход пульта» программа не нужна: это сценарий (pack.auto). Программа — когда нужна своя логика: счёт, датчики, черепашка, несколько шагов с проверками.

```lua
-- Сторож дверей: по событию ЛОЦМАНа lockdown закрывает железные двери и держит их,
-- unlock — открывает; нажали кнопку у двери — сообщает ЛОЦМАНу событием door_button.
-- ===== настройки =====
local PROTO = "tmai_event"        -- протокол событий сценариев ЛОЦМАНа
local DOOR_SIDE = "back"          -- выход к железным дверям: true = открыто
local BUTTON_SIDE = "front"       -- вход: кнопка или нажимная плита у двери
local OWNER = settings.get("tmexec.owner")   -- id компьютера ЛОЦМАНа (записал агент)

if not rednet.isOpen() then peripheral.find("modem", rednet.open) end
if not rednet.isOpen() then error("No modem attached", 0) end

local locked = false

local function set_doors(open)
  redstone.setOutput(DOOR_SIDE, open)
end

-- событие ЛОЦМАНу (без owner — всем: ЛОЦМАН тоже услышит)
local function notify(name, data)
  local msg = { name = name, data = data }
  if OWNER then rednet.send(OWNER, msg, PROTO) else rednet.broadcast(msg, PROTO) end
end

set_doors(true)
print("Door guard ready, LOCMAN id " .. tostring(OWNER))
local last = redstone.getInput(BUTTON_SIDE)
while true do
  local ev, id, msg, proto = os.pullEvent()
  if ev == "rednet_message" and proto == PROTO and type(msg) == "table" and type(msg.name) == "string" then
    if OWNER == nil or id == OWNER then          -- команды только от ЛОЦМАНа
      if msg.name == "lockdown" then
        locked = true
        set_doors(false)
        print("LOCKDOWN: doors closed")
      elseif msg.name == "unlock" then
        locked = false
        set_doors(true)
        print("Unlocked: doors open")
      end
    end
  elseif ev == "redstone" then
    local now = redstone.getInput(BUTTON_SIDE)
    if now and not last then
      notify("door_button", locked and "locked" or "open")
      print("Button: LOCMAN notified")
    end
    last = now
  end
end
```

ПАРНЫЕ СЦЕНАРИИ (auto_add, формат pack.auto): фраза «осада» → {"type":"event","name":"lockdown"}; «отбой» → {"type":"event","name":"unlock"}; when {"type":"event","name":"door_button"} → {"type":"say","text":"У двери кто-то есть"}. Скажи игроку: компьютер у дверей с модемом, двери — на сторону back, кнопка — на front (или поменяй настройки), «tmexec startup», затем «да КОД».
