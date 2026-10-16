МОДЕМЫ
- Беспроводной: дальность в сборке 64 блока у земли, растёт с высотой до 512 у потолка мира (у обоих концов берётся лучшее). Эндер-модем — без ограничений и между измерениями. Проводной — по кабелю, без ограничений дальности.
- tmexec уже открыл все модемы для rednet. В обычной программе: peripheral.find("modem", rednet.open) — открыть все; или rednet.open("back").
- Поиск только беспроводного: peripheral.find("modem", function(_, m) return m.isWireless() end).

REDNET
- rednet.send(id, сообщение[, протокол]) → bool (true — отправлено, не «доставлено»).
- rednet.broadcast(сообщение[, протокол]).
- local id, msg, proto = rednet.receive([протокол][, таймаут_сек]) → nil при таймауте. Без таймаута ждёт вечно.
- Событие rednet_message(id, сообщение, протокол) — для цикла событий.
- Сообщение — число, строка, bool или таблица (копируется; функции и циклические ссылки нельзя).
- rednet.host(протокол, "имя") — объявить себя; rednet.lookup(протокол[, "имя"][, таймаут]) → id (или все id). rednet.unhost(протокол).
- os.getComputerID() — свой id. Протоколы "tmai_*" заняты капсулой — свои называй уникально, например "tm_farm_v1".

НАДЁЖНЫЙ ЗАПРОС-ОТВЕТ
```lua
local PROTO = "tm_door_v1"
-- клиент: запрос с номером, ждём ответ с тем же номером, повторяем
local function request(server, cmd, tries)
  local req = { cmd = cmd, n = math.random(1, 1e9) }
  for _ = 1, tries or 3 do
    rednet.send(server, req, PROTO)
    local deadline = os.clock() + 2
    while os.clock() < deadline do
      local id, msg = rednet.receive(PROTO, deadline - os.clock())
      if id == server and type(msg) == "table" and msg.n == req.n then return msg end
    end
  end
  return nil, "no reply"
end
```
Сервер: rednet.host(PROTO, "door1"); в цикле rednet.receive(PROTO) → проверить отправителя и поля → выполнить → rednet.send(id, { n = msg.n, ok = true }, PROTO). Полный пример — lua.ex.rednet.

БЕЗОПАСНОСТЬ
- Любой компьютер может прислать что угодно: проверяй type(msg) == "table", допустимые команды и белый список id отправителей (ALLOWED = { [12] = true }).
- Не выполняй присланный код (load) и не давай удалённо менять файлы.

МОДЕМ НАПРЯМУЮ (каналы 0–65535)
- modem.open(канал), modem.transmit(канал, канал_ответа, сообщение), modem.close(канал), modem.closeAll(), modem.isOpen(канал).
- Событие modem_message(сторона, канал, канал_ответа, сообщение, дистанция) — дистанция только у беспроводных.
- rednet занимает канал id % 65500 каждого компьютера, 65533 и 65535 — для своих каналов бери другие числа.

GPS
- gps.locate([таймаут]) → x, y, z или nil. Нужны 4 GPS-хоста с беспроводными модемами, расставленные не в одной плоскости, на каждом: gps host x y z (через shell — это делает игрок; tmexec shell не даёт).
- Черепашке без GPS координаты считай сама от старта (lua.turtle_nav).

ЧАСТЫЕ ОШИБКИ
- Модем не открыт → сообщения не приходят (rednet.isOpen()).
- Ожидание без таймаута блокирует программу навсегда, если второй компьютер выключен.
- sleep в том же потоке, где ждёшь rednet_message, — сообщения во время sleep теряются (lua.events).
- Компьютер-приёмник в выгруженном чанке не получает ничего.
