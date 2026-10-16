МОДЕЛЬ
Программа CC работает, пока не уступит управление (yield). Yield происходит внутри os.pullEvent, sleep, rednet.receive, turtle.*, http.get и почти всех методов периферии модов (они выполняются в основном потоке сервера: минимум 1 тик = 0.05 с на вызов). Код, который ~7 с не уступал, получает ошибку «Too long without yielding»; если не реагирует и дальше — компьютер выключается.
- Тяжёлый расчёт без периферии: раз в ~1000 итераций — os.queueEvent("y"); os.pullEvent("y").
- 1000 вызовов периферии = 50+ с. Кэшируй: chest.list() один раз за цикл, а не getItemDetail по каждому слоту без нужды.
- Вызов метода периферии внутри ждёт своё событие task_complete — события, пришедшие за этот тик, ЭТОЙ корутине не достанутся (как при sleep). Опрос периферии и реакцию на события разделяй через parallel.

ОЖИДАНИЕ СОБЫТИЙ
- local ev, a, b, c = os.pullEvent() — любое событие; os.pullEvent("timer") — только нужное (остальные выбрасываются!).
- os.pullEventRaw() — то же, но получает "terminate" как обычное событие (Ctrl+T); os.pullEvent при terminate бросает ошибку "Terminated".
- local id = os.startTimer(сек) → позже событие "timer", id. Сверяй id: таймеров может быть несколько. os.cancelTimer(id).
- os.setAlarm(игровое_время 0–24) → "alarm", id.
- sleep(n) внутри ждёт свой таймер и ВЫБРАСЫВАЕТ все прочие события (клик по монитору, rednet). Реагирующей программе нужен цикл событий с таймером:

```lua
local PERIOD = 1                       -- раз в секунду — работа по таймеру
local timer = os.startTimer(PERIOD)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "timer" and a == timer then
    tick()                              -- периодическая проверка
    timer = os.startTimer(PERIOD)
  elseif ev == "monitor_touch" then onTouch(a, b, c)    -- сторона, x, y
  elseif ev == "rednet_message" then onMsg(a, b, c)     -- id, сообщение, протокол
  elseif ev == "redstone" then onRedstone()
  end
end
```

PARALLEL
- parallel.waitForAny(f1, f2, …) — крутит функции вместе, пока любая не закончится; waitForAll — пока все. Каждая получает свою копию событий (sleep в одной не крадёт события у другой). Передавай функции, не вызовы: parallel.waitForAny(loopA, loopB), не loopA(). Ошибка в любой — ошибка всего.
- Надёжный шаблон «опрос + реакция»: одна функция — while true do poll(); sleep(N) end (вызовы периферии здесь), другая — while true do local ev = { os.pullEvent() } … end (клики, rednet, чат). Общие данные — в local-таблицах; разбудить другую функцию — os.queueEvent("имя").

СВОИ СОБЫТИЯ И КОРУТИНЫ
- os.queueEvent("имя", данные…) — положить событие в очередь своего компьютера.
- coroutine.create/resume/yield работают, но yield корутины — это и есть ожидание события: собственный диспетчер передаёт события через resume. Проще использовать parallel.

СОБЫТИЯ CC: TWEAKED (аргументы после имени)
- timer(id), alarm(id), terminate(), term_resize()
- key(код, удержание), key_up(код), char(символ), paste(текст); keys.enter, keys.q, keys.getName(код)
- mouse_click(кнопка, x, y), mouse_up, mouse_drag, mouse_scroll(направление, x, y) — продвинутые компьютеры
- monitor_touch(сторона_монитора, x, y) — продвинутый монитор; monitor_resize(сторона)
- redstone() — изменился любой вход редстоуна (какой — смотри redstone.getInput)
- peripheral(сторона), peripheral_detach(сторона)
- rednet_message(id_отправителя, сообщение, протокол); modem_message(сторона, канал, канал_ответа, сообщение, дистанция)
- turtle_inventory() — изменился инвентарь черепашки
- http_success(url, ответ), http_failure(url, ошибка, ответ); websocket_success/failure/message/closed
- disk(сторона), disk_eject(сторона); speaker_audio_empty(имя_колонки)
- Advanced Peripherals: chat(uuid, ник, текст, скрыто, текст_utf8); player_join(uuid, ник, измерение); player_leave(uuid, ник, измерение); player_changed_dimension(uuid, ник, из, в); player_click(имя_периферии, uuid, ник); ae_crafting(ошибка, id_задания, сообщение)
- Create: speed_change(скорость), stress_change(нагрузка, ёмкость), overstressed(), train_arrival/train_departure/train_imminent, train_passing/train_passed (lua.create)

ТИПОВЫЕ ОШИБКИ
- Ждать событие от периферии, которое она не шлёт (у Mekanism и Extreme Reactors событий нет) — опрашивай по таймеру.
- Забыть перезапустить таймер после срабатывания — цикл «зависнет» навсегда.
- os.pullEvent("rednet_message") в одном месте и sleep в другом месте того же потока — сообщения теряются; используй parallel или общий цикл событий.
