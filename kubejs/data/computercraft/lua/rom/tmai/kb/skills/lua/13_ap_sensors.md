Сверено с jar 0.8.2a. Redstone Integrator в 0.8 нет — используйте реле CC (lua.redstone).

ДЕТЕКТОРЫ ПОТОКА (типы "energy_detector", "fluid_detector", "gas_detector" (Mekanism))
Блок ставится в разрыв линии: вход с одной стороны, выход с противоположной; работает как «резистор».
- getTransferRate() → текущий поток (FE/t, мB/t); getTransferRateLimit(); setTransferRateLimit(n) — ограничить поток; getMaxTransferRate() — потолок.
- getLastTransferedId(), getReadyTransferId() — что прошло/готово пройти (жидкость/газ).

ДЕТЕКТОР ОКРУЖЕНИЯ (тип "environment_detector"; есть апгрейд черепашки)
- getBiome(), getDimension(), listDimensions(), getTime(), getMoon() → номер 0–7 и название, isRaining(), isThunder(), isSunny(), isSlimeChunk().
- getBlockLightLevel(), getSkyLightLevel(), getDayLightLevel() — 0–15.
- getRadiation() → { radiation = "…", unit = "…" }, getRadiationRaw() → Зв/ч (с Mekanism).
- scanEntities(радиус[, подробно[, фильтр "#тег" или id]]) → сущности с относительными x, y, z. Радиус до 8 бесплатно, до 16 — за энергию; пауза 2 с.
- canSleepHere(), canPlayerSleep("Ник").

ГЕО-СКАНЕР (тип "geo_scanner"; есть апгрейд черепашки)
- scanBlocks(радиус) → { {name, tags, state, x, y, z}, … } (координаты относительно сканера) или nil, ошибка. Радиус ≤ 8 бесплатно, до 16 — тратит энергию/топливо; между сканами ~2 с.
- chunkAnalyze([фильтр]) → { ["minecraft:iron_ore"] = кол-во, … } по чанку сканера.
- getFuelLevel(), getMaxFuelLevel() (энергия блока).

```lua
local geo = peripheral.find("geo_scanner") or error("No geo scanner", 0)
local blocks, err = geo.scanBlocks(8)
if not blocks then error("Scan failed: " .. tostring(err), 0) end
for _, b in ipairs(blocks) do
  if b.tags and b.tags["c:ores"] then print(b.name, b.x, b.y, b.z) end
end
```
tags — словарь { ["c:ores"] = true, … } (как у предметов CC). При сомнениях в структуре выведи textutils.serialize(blocks[1]).

ЧТЕЦ БЛОКОВ (тип "block_reader"; смотрит на блок перед собой)
- getBlockName() → id; getBlockState() → таблица свойств; getBlockData() → NBT блок-сущности (таблица); hasBlockEntity().

ДЕТЕКТОР ДИСТАНЦИИ (тип "distance_detector")
- getDistance(), calculateDistance(), getMaxRange()/setMaxRange(n), setDetectionMode("block"|"entity"|"both"), setLaserVisibility(b), setCalculatePeriodically(b).

ХРАНИЛИЩЕ NBT (тип "nbt_storage"): load() → таблица, save(таблица или SNBT).

УМНЫЕ РЕЛЬСЫ (тип "smart_rail"): hasCarts(), getCarts(), getState()/setState(…), isActivating()/setActivating(b); события cart_attached, cart_detached.
Умные очки AP (оверлей, клавиатура) — отдельная тема, в программах для tmexec не используем. RS-мост и интегратор колонии есть в моде, но Refined Storage и MineColonies в сборке нет.

ЧЕРЕПАШКИ И ЯДРА AP (апгрейды; видны как peripheral "left"/"right")
- Контроллер чанков (chunky): держит загруженным чанк черепашки; getRadius(). Ставьте долгим копателям.
- compass: getFacing() → сторона света.
- Ядра автоматов (weak/husbandry/end, overpowered): digBlock(), useOnBlock(), placeBlock(), lookAtBlock(), lookAtEntity(), collectItems(), scanItems(), useOnAnimal(), captureAnimal()/releaseAnimal(), savePoint()/warpToPoint() (end), chargeTurtle(); у части — getFuelLevel/getMaxFuelLevel. Имеют перезарядку (1–5 с) и тратят топливо черепашки. Аргументы — таблица; при сомнении печатай peripheral.getMethods("right").

POWAH ЧЕРЕЗ AP (блоки Powah прямо как периферия; тип смотри peripheral.getType)
- Энергоячейка: getStoredEnergy(), getMaxEnergy(); эндер-ячейка: + getChannel()/setChannel(n), getMaxChannels().
- Реактор Powah: isRunning(), getFuel(), getCarbon(), getRedstone(), getStoredEnergy(), getMaxEnergy(), getTemperature(), get…Slot().
- Печь-генератор (furnator): isBurning(), getStoredEnergy(), getMaxEnergy(), getCarbon(); магматор: getFuelTank(); термогенератор: getCoolantTank(); солнечная панель: canSeeSky().

CREATE ЧЕРЕЗ AP (дополнительно к своим перифериям Create — lua.create)
- Чаша (basin): inputTanks(), outputTanks(). Горелка ифрита: info(). Бак Create: info(). Блоки с фильтром: getFilter(), setFilter(предмет). Блоки с прокруткой значения: getScrollValue(), setScrollValue(n).

МАЯК, НОТНЫЙ БЛОК (ваниль через AP): beacon — getLevel(), getPrimaryEffect(), getSecondaryEffect(); note block — playNote(), getNote(), changeNote(), changeNoteBy(n).
