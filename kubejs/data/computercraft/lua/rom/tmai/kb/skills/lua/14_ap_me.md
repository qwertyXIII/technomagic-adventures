Тип "me_bridge". Мост — часть МЭ-сети (кабель AE2) и периферия компьютера (вплотную или проводным модемом). Методы из jar 0.8.2a (документация AP местами расходится — верь этому разделу). Ошибки: nil, "КОД" (NOT_CONNECTED, ITEM_NOT_FOUND, NOT_CRAFTABLE, …).

СОСТОЯНИЕ
- isConnected() — мост в сети; isOnline() — сеть запитана и работает. Всегда проверяй isOnline() перед работой.
- getStoredEnergy(), getEnergyCapacity(), getEnergyUsage(), getAverageEnergyInput() — энергия AE.
- Место (байты AE2): getMaxItemStorage(), getUsedItemStorage(), getAvailableItemStorage(); то же Fluid и Chemical; внешние хранилища (шины): getMaxExternalItemStorage(), getUsedExternalItemStorage(), getAvailableExternalItemStorage(), getMaxExternalItemCount()/getUsedExternalItemCount()/getAvailableExternalItemCount().
- getCells() — ячейки в приводах; getDrives() — приводы.

ФИЛЬТР (таблица во всех методах)
{ name = "minecraft:iron_ingot" } — id; { name = "#c:ingots/iron" } — тег; count = N — количество; components = {…} или SNBT; fingerprint = "…" (из ответа getItems); nbtHash. Пустой фильтр {} — всё.

ЗАПАСЫ
- getItems([фильтр]) → массив предметов; getItem(фильтр) → первый найденный или nil, "ITEM_NOT_FOUND" (значит 0 шт.).
- Предмет: { name, count, displayName, maxStackSize, tags, components, fingerprint, isCraftable }.
- getFluids/getFluid, getChemicals/getChemical — то же для жидкостей (мB) и химии Mekanism.
- getCraftableItems([фильтр]) — что умеет крафтить сеть (есть шаблон); getPatterns([{ output = фильтр } или { input = фильтр }]) → шаблоны {primaryOutput, outputs, inputs, patternType}.

ПЕРЕНОС
- exportItem(куда, фильтр) → сколько ушло (по умолчанию до 64); importItem(откуда, фильтр) → сколько пришло. куда/откуда: "@up", "@down", "@north", "@south", "@east", "@west" — инвентарь вплотную к мосту, или имя периферии в той же сети ("minecraft:chest_2").
- exportFluid/importFluid(куда, фильтр), exportChemical/importChemical — то же.

АВТОКРАФТ
- isCraftable(фильтр) → bool; isCrafting(фильтр) → уже идёт крафт этого предмета.
- craftItem({ name = id, count = n }[, имя_процессора]) → объект задания или nil, ошибка. Не блокирует: расчёт идёт в фоне, результат — событием.
- Объект задания (вызов через точку): getId(), isDone(), isCanceled(), isCraftingStarted(), isCalculationStarted(), isCalculationNotSuccessful(), hasErrorOccurred(), getDebugMessage(), getRequestedItem(), getElapsedTime(), getTotalItems(), getItemProgress(), getEmittedItems(), getUsedItems(), getMissingItems(), hasMultiplePaths(), getFinalOutput(), getUsedBytes(), getCraftingCPU(), cancel().
- Событие "ae_crafting"(ошибка:boolean, id, сообщение). Сообщения: "CRAFTING_STARTED", "MISSING_ITEMS" (смотри job.getMissingItems()), "NOT_CRAFTABLE", "CPU_NOT_FOUND", "JOB_DONE", "JOB_CANCELED". В документации AP событие названо me_crafting — в jar 0.8.2a оно "ae_crafting"; надёжнее проверять оба имени.
- getCraftingTasks() → идущие задания {id, quantity, resource, completion 0..1, crafted, cpu, bridge_id}; getCraftingTask(id); cancelCraftingTasks(фильтр) → число отменённых.
- getCraftingCPUs() → { {name, storage, coProcessors, isBusy, craftingJob, selectionMode}, … }. Нет свободных процессоров — новые заказы ждут.

```lua
local me = peripheral.find("me_bridge") or error("No ME bridge", 0)
assert(me.isOnline(), "ME network offline")
local function stock(id)
  local it = me.getItem({ name = id })
  return type(it) == "table" and (it.count or 0) or 0
end
local function order(id, n)
  if me.isCrafting({ name = id }) then return nil, "already crafting" end
  if not me.isCraftable({ name = id }) then return nil, "no pattern" end
  return me.craftItem({ name = id, count = n })
end
local job, err = order("minecraft:iron_ingot", 64)
while job do
  local ev, isErr, id, msg = os.pullEvent()
  if (ev == "ae_crafting" or ev == "me_crafting") and id == job.getId() then
    print(isErr and "Fail: " or "OK: ", msg)
    if isErr or msg == "CRAFTING_STARTED" then break end
  end
end
```

ПРАВИЛА
- Лимиты в настройках: максимум за заказ, суммарно за цикл; не заказывай повторно, пока isCrafting(…) = true.
- Опрос запасов раз в 10–30 с: каждый вызов — тик сервера, getItems() без фильтра на большой сети тяжёлый — фильтруй.
- Не выгружай всё из сети (exportItem без count) без явной просьбы.
