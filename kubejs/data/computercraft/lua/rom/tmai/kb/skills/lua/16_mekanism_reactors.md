Из MekanismGenerators-1.21.1-10.7.19.85.jar. Методы мультиблока доступны через любой порт/адаптер; сначала isFormed(). Событий нет — опрос раз в 0.5–1 с.

РЕАКТОР ДЕЛЕНИЯ — типы "fissionReactorLogicAdapter" (логический адаптер) и "fissionReactorPort" (порт)
- Состояние: getStatus() → true = работает; isForceDisabled(); getTemperature() → Кельвины; getDamagePercent() → 0–100; getHeatCapacity(); getEnvironmentalLoss(); getHeatingRate(); getBoilEfficiency().
- Мощность: getBurnRate() (заданная, мB/т), getActualBurnRate(), getMaxBurnRate(); setBurnRate(n) (0 … max).
- Управление: activate() — только если выключен; scram() — только если включён (иначе ошибка — проверь getStatus() или pcall).
- Баки (у каждого X: getX(), getXCapacity(), getXNeeded(), getXFilledPercentage() → 0..1):
  Fuel (топливо), Coolant (вода или натрий), HeatedCoolant (пар или горячий натрий), Waste (отходы).
- getFuelAssemblies(), getFuelSurfaceArea(); размеры getLength()/getWidth()/getHeight().
- Логический адаптер: getLogicMode()/setLogicMode("DISABLED"|"ACTIVATION"|"TEMPERATURE"|"CRITICAL_WASTE_LEVEL"|"DAMAGED"|"DEPLETED"), getRedstoneLogicStatus(). Порт: getMode()/setMode("INPUT"|"OUTPUT_WASTE"|"OUTPUT_COOLANT").
- ОПАСНОСТЬ: урон растёт при температуре выше 1200 K (быстро к 1800 K); при 100 % урона — взрыв и радиация. Перегрев — от нехватки охлаждения (Coolant падает), переполнения нагретого теплоносителя (HeatedCoolant → 100 %: турбина/котёл не успевают) и отходов (Waste → 100 %).
- Аварийная защита (scram) при: temperature ≥ 1000 K, damage > 0, coolant < 20 %, heatedCoolant > 90 %, waste > 90 %. Повторный пуск — только вручную или после возврата всех показателей в норму, если игрок явно разрешил авто-пуск. Пример — lua.ex.reactor_mek.

ТУРБИНА ("turbineValve")
- isFormed(); getSteam()…getSteamFilledPercentage(); getFlowRate(), getMaxFlowRate(), getMaxWaterOutput(); getProductionRate(), getMaxProduction() — J/т; энергия getEnergy(), getMaxEnergy(), getEnergyFilledPercentage().
- getBlades(), getVents(), getCoils(), getCondensers(), getDispersers(); getDumpingMode()/setDumpingMode("IDLE"|"DUMPING_EXCESS"|"DUMPING"), incrementDumpingMode().
- Полный буфер турбины → она не принимает пар → пар копится в реакторе (HeatedCoolant растёт) → нужен scram или сброс пара (DUMPING_EXCESS).

КОТЁЛ ("boilerValve")
- isFormed(); getTemperature() (K); getBoilRate(), getMaxBoilRate(), getBoilCapacity(), getSuperheaters(), getEnvironmentalLoss().
- Баки: Water, Steam, HeatedCoolant, CooledCoolant — по схеме getX(), getXCapacity(), getXNeeded(), getXFilledPercentage().
- getMode()/setMode(…), incrementMode() — режим клапана.

ТЕРМОЯДЕРНЫЙ РЕАКТОР — "fusionReactorLogicAdapter", "fusionReactorPort"
- isFormed(); isIgnited(); getPlasmaTemperature(), getCaseTemperature() (K); getIgnitionTemperature(охлаждаемый:boolean), getMaxPlasmaTemperature(b), getMaxCasingTemperature(b).
- Впрыск: getInjectionRate(), setInjectionRate(n) (чётное число), getMinInjectionRate(b).
- Энергия: getProductionRate(), getPassiveGeneration(b), getTransferLoss(), getEnvironmentalLoss().
- Баки: Water, Steam, Deuterium, Tritium, DTFuel — схема getX…/getXFilledPercentage(); getHohlraum().
- Адаптер: isActiveCooledLogic()/setActiveCooledLogic(b), getLogicMode()/setLogicMode("DISABLED"|"READY"|"CAPACITY"|"DEPLETED"). Порт: getMode()/setMode(true = выход).
- Fusion не взрывается; остановка — setInjectionRate(0).

```lua
-- безопасное чтение мультиблока
local r = peripheral.find("fissionReactorLogicAdapter") or peripheral.find("fissionReactorPort")
  or error("No fission reactor adapter/port", 0)
local function get(name, ...)
  local ok, v = pcall(r[name], ...)
  if ok then return v end
  return nil, v
end
if not get("isFormed") then error("Reactor not formed", 0) end
print(("T=%.0fK dmg=%.1f%% waste=%.0f%%"):format(get("getTemperature"), get("getDamagePercent"),
  get("getWasteFilledPercentage") * 100))
```
