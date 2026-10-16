Из create-1.21.1-6.0.10.jar (встроенная поддержка CC). Блок — периферия, если к нему вплотную компьютер или проводной модем. Имена типов с префиксом Create_.

КИНЕТИКА
- "Create_Speedometer": getSpeed() → об/мин (со знаком направления). Событие speed_change(скорость).
- "Create_Stressometer": getStress() (текущая нагрузка, SU), getStressCapacity() (ёмкость сети). События stress_change(нагрузка, ёмкость), overstressed().
- "Create_RotationSpeedController": setTargetSpeed(n) (−256…256 об/мин), getTargetSpeed().
- "Create_CreativeMotor": setGeneratedSpeed(n), getGeneratedSpeed().
- "Create_SequencedGearshift": rotate(угол_градусы[, множитель]) и move(блоков[, множитель]) — множитель 1/2 вперёд, −1/−2 назад (2 — вдвое быстрее); isRunning() → идёт ли команда. Жди окончания: while sg.isRunning() do sleep(0.1) end.
- "Create_Sticker": extend(), retract(), toggle(), isExtended(), isAttachedToBlock().

ТЕКСТ НА ТАБЛИЧКИ И ДИСПЛЕИ
- "Create_DisplayLink": setCursorPos(x, y), getCursorPos(), getSize() → строки, столбцы цели; write(text), writeBytes(…), clearLine(), clear(), isColor(); update() — ОБЯЗАТЕЛЬНО вызвать, чтобы отправить текст на табло/лекторн/табличку.
- "Create_NixieTube": setText(text[, цвет]), setTextColor("red"…), setSignal(таблица) — для сигнальных огней.

```lua
local link = peripheral.find("Create_DisplayLink") or error("No display link", 0)
local stress = peripheral.find("Create_Stressometer") or error("No stressometer", 0)
while true do
  local used, cap = stress.getStress(), stress.getStressCapacity()
  link.clear()
  link.setCursorPos(1, 1); link.write(("Stress %.0f / %.0f SU"):format(used, cap))
  link.setCursorPos(1, 2); link.write(cap > 0 and ("%.0f%%"):format(used / cap * 100) or "no power")
  link.update()
  sleep(2)
end
```

ПОЕЗДА
- "Create_Station": isTrainPresent(), isTrainImminent(), isTrainEnroute(), getTrainName()/setTrainName(n), getStationName()/setStationName(n), hasSchedule(), getSchedule()/setSchedule(таблица), canTrainReach(станция), distanceTo(станция), assemble(), disassemble(), setAssemblyMode(b), isInAssemblyMode(). События train_arrival, train_departure, train_imminent.
- "Create_Signal": getState(), isForcedRed()/setForcedRed(b), listBlockingTrainNames(), getSignalType(), cycleSignalType(). Событие train_signal_state_change.
- "Create_TrainObserver": isTrainPassing(), getPassingTrainName(). События train_passing, train_passed.

ЛОГИСТИКА CREATE 6 (пакеты)
- "Create_StockTicker": stock([подробно]) → запасы сети, getStockItemDetail(i), requestFiltered(адрес, фильтр…) → заказать доставку, list(), getItemDetail(слот).
- "Create_Packager"/"Create_Repackager": makePackage(), getAddress()/setAddress(a), list(), getItemDetail(слот), getPackage(). Событие package_repackaged.
- "Create_Postbox", "Create_Frogport": getAddress()/setAddress(a), getConfiguration()/setConfiguration("send"|"send_recieve"), list(), getItemDetail(слот).
- "Create_RedstoneRequester": request(), setRequest(…), setCraftingRequest(…), getRequest(), setAddress(a), getConfiguration()/setConfiguration("allow_partial"|"strict").
- "Create_TableClothShop": isShop(), getWares()/setWares(…), getPriceTagItem()/setPriceTagItem(…), getPriceTagCount()/setPriceTagCount(n), getAddress()/setAddress(a).

ЧЕРЕЗ ADVANCED PERIPHERALS (lua.ap.sensors): чаша (inputTanks, outputTanks), горелка ифрита (info), бак (info), фильтры (getFilter, setFilter), значения-прокрутки (getScrollValue, setScrollValue).

ЗАМЕЧАНИЯ
- Методы, меняющие мир (setTargetSpeed, rotate, assemble), выполняются в тик сервера; не дёргай их чаще нескольких раз в секунду.
- Перегруз сети (overstressed) останавливает всю кинетику — разумная реакция: снизить скорость контроллером или отключить потребителей сцеплением через редстоун.
- Аргументы setSchedule/requestFiltered — сложные таблицы; если не уверен в формате — сначала прочитай getSchedule() и меняй его.
