Из ExtremeReactors2-1.21.1-2.4.9.jar (+ ZeroCore2). Компьютерный порт есть только у усиленных (reinforced) реакторов и турбин и у энергонакопителя (Energizer). Порт — часть стенки мультиблока; компьютер вплотную к порту или проводной модем на порту.

ТИПЫ: "BigReactors-Reactor", "BigReactors-Turbine", "BigReactors-Energizer".

ОБЩЕЕ (мультиблок ZeroCore)
- mbIsAssembled() — собран ли; mbIsConnected(), mbIsPaused(), mbIsDisassembled(); mbGetMinimumCoordinate(), mbGetMaximumCoordinate(), mbGetMultiblockControllerTypeName().
- getVariant() — вариант (basic/reinforced). Неверный аргумент → ошибка «Invalid argument N…».

РЕАКТОР
- getActive() / setActive(bool).
- Энергия (FE): getEnergyStored(), getEnergyCapacity(), getEnergyProducedLastTick(), getEnergyStoredAsText(); getEnergyStats() → { energyStored, energyCapacity, energyProducedLastTick, energySystem }.
- Топливо: getFuelAmount(), getFuelAmountMax(), getWasteAmount(), getFuelReactivity() (%), getFuelConsumedLastTick() (мB); getFuelStats() → { fuelAmount, fuelCapacity, fuelTemperature, fuelConsumedLastTick, fuelReactivity, wasteAmount }.
- Температуры (°C): getFuelTemperature(), getCasingTemperature().
- Стержни: getNumberOfControlRods(); getControlRodLevel(i), setControlRodLevel(i, 0–100) — i с 0; setAllControlRodLevels(0–100) (100 = полностью вставлены = минимум мощности); getControlRodsLevels() → { [i] = уровень }; setControlRodsLevels(таблица); getControlRodName(i)/setControlRodName(i, имя); getControlRodLocation(i).
- Активное охлаждение (пар для турбин): isActivelyCooled(); getCoolantAmount(), getCoolantAmountMax(), getCoolantType(); getHotFluidAmount(), getHotFluidAmountMax(), getHotFluidType(), getHotFluidProducedLastTick(); getCoolantFluidStats(), getHotFluidStats() → { fluidType, fluidAmount, fluidCapacity[, fluidProducedLastTick] }.
- doEjectWaste(), doEjectFuel() — выгрузить отходы/топливо в порты доступа.

ТУРБИНА
- getActive()/setActive(b); getRotorSpeed() (об/мин), getNumberOfBlades(), getBladeEfficiency() (%), getRotorMass().
- getInductorEngaged()/setInductorEngaged(b) — катушки: выкл → ротор разгоняется без выработки.
- Пар: getFluidFlowRate(), getFluidFlowRateMax()/setFluidFlowRateMax(мB/т), getFluidFlowRateMaxMax(); getInputAmount(), getInputType(), getOutputAmount(), getOutputType(), getFluidAmountMax().
- Энергия: getEnergyStored(), getEnergyCapacity(), getEnergyProducedLastTick(), getEnergyStats().
- Вентиляция: setVentNone(), setVentOverflow(), setVentAll().
- Рабочие обороты ротора ≈ 900 или 1800 об/мин (максимум эффективности); выше ~2000 — потери. Держи обороты катушками и потоком пара.

ЭНЕРГОНАКОПИТЕЛЬ: getActive()/setActive(b), getEnergyStored(), getEnergyCapacity(), getEnergyIoLastTick(), getEnergyInsertedLastTick(), getEnergyExtractedLastTick(), getEnergyStats(), getEnergyStatsAsText().

ОСОБЕННОСТИ
- Реакторы Extreme Reactors не взрываются, но при перегреве падает эффективность, а при полном буфере энергия теряется. Защита — выключение по температуре и по заполнению буфера, плавная регулировка стержнями.
- Простое регулирование: уровень стержней = доля заполнения буфера × 100 (буфер полон — стержни вставлены).
- Методы при несобранном мультиблоке дают ошибку — проверяй mbIsAssembled() и оборачивай в pcall.

```lua
local r = peripheral.find("BigReactors-Reactor") or error("No reactor computer port", 0)
if not r.mbIsAssembled() then error("Reactor not assembled", 0) end
local fill = r.getEnergyStored() / math.max(1, r.getEnergyCapacity())
r.setAllControlRodLevels(math.floor(fill * 100))
print(("Fuel %.0fC casing %.0fC fill %.0f%%"):format(r.getFuelTemperature(), r.getCasingTemperature(), fill * 100))
```
Полная защита с гистерезисом — lua.ex.reactor_er.
