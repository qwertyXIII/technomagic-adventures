Имена методов и типов — из Mekanism-1.21.1-10.7.19.85.jar. Каждый блок Mekanism с поддержкой компьютеров — периферия (вплотную или через проводной модем). Событий Mekanism не шлёт — только опрос.

ТИПЫ (peripheral.find("тип"))
- Энергоячейки: "basicEnergyCube", "advancedEnergyCube", "eliteEnergyCube", "ultimateEnergyCube", "creativeEnergyCube".
- Индукционная матрица: "inductionPort". Динамический бак: "dynamicValve". Термоиспаритель: "thermalEvaporationController"/"thermalEvaporationValve". SPS: "spsPort". Котёл: "boilerValve".
- Генераторы: "heatGenerator", "bioGenerator", "solarGenerator", "advancedSolarGenerator", "windGenerator", "gasBurningGenerator"; турбина "turbineValve"; реакторы — lua.mekanism.reactors.
- Машины: "enrichmentChamber", "crusher", "energizedSmelter", "precisionSawmill", "osmiumCompressor", "combiner", "metallurgicInfuser", "purificationChamber", "chemicalInjectionChamber", "pressurizedReactionChamber", "chemicalCrystallizer", "chemicalDissolutionChamber", "chemicalInfuser", "chemicalOxidizer", "chemicalWasher", "rotaryCondensentrator", "electrolyticSeparator", "isotopicCentrifuge", "nutritionalLiquifier", "antiprotonicNucleosynthesizer", "solarNeutronActivator", "digitalMiner", "formulaicAssemblicator", "electricPump", "fluidicPlenisher", "resistiveHeater", "fuelwoodHeater", "seismicVibrator", "teleporter", "chargepad", "laser", "laserAmplifier", "laserTractorBeam", "logisticalSorter", "oredictionificator", "quantumEntangloporter", "radioactiveWasteBarrel", "industrialAlarm", "dimensionalStabilizer", "modificationStation", "pigmentExtractor", "pigmentMixer", "paintingMachine", "securityDesk", "personalChest", "personalBarrel", QIO: "qioDriveArray", "qioDashboard", "qioImporter", "qioExporter", "qioRedstoneAdapter". Фабрики — с уровнем в начале имени; точный тип — peripheral.getType.

ЭНЕРГИЯ — В ДЖОУЛЯХ (J). 1 FE = 2.5 J по умолчанию.
- Глобальный API на любом компьютере: mekanismEnergyHelper.joulesToFE(j), mekanismEnergyHelper.feToJoules(fe).
- Общие методы блоков с энергией: getEnergy(), getMaxEnergy(), getEnergyNeeded(), getEnergyFilledPercentage() → 0..1 (доля, не проценты!).
- Общие методы: getDirection(), getRedstoneMode()/setRedstoneMode("DISABLED"|"HIGH"|"LOW"|"PULSE") (DISABLED — сигнал игнорируется), getComparatorLevel(); безопасность: getOwnerName(), getSecurityMode() (сеттеры работают только у блоков с публичным доступом).
- Конфигурация сторон и апгрейды: getInstalledUpgrades(), getSupportedUpgrades(), getMode(тип, сторона), setMode(…), isEjecting(тип)/setEjecting(тип, bool).

ЭНЕРГОЯЧЕЙКА: общие методы энергии + getChargeItem(), getDischargeItem().

ИНДУКЦИОННАЯ МАТРИЦА ("inductionPort")
- isFormed() — сначала проверь! Иначе остальные методы падают.
- getEnergy(), getMaxEnergy(), getEnergyFilledPercentage(), getEnergyNeeded() (J).
- getLastInput(), getLastOutput() — J за последний тик; getTransferCap() — предел J/т; getInstalledCells(), getInstalledProviders().
- getLength(), getWidth(), getHeight(), getMinPos(), getMaxPos(); getMode() → true = выход, false = вход; setMode(bool) — порт на выдачу/приём.

```lua
local m = peripheral.find("inductionPort") or error("No induction port", 0)
local function fe(j) return mekanismEnergyHelper and mekanismEnergyHelper.joulesToFE(j) or j / 2.5 end
local ok, formed = pcall(m.isFormed)
if not (ok and formed) then error("Induction matrix not formed", 0) end
print(("Stored %.1f%%"):format(m.getEnergyFilledPercentage() * 100))
print(("In %.0f FE/t, out %.0f FE/t"):format(fe(m.getLastInput()), fe(m.getLastOutput())))
```

МАШИНЫ (электрические)
- getInput(), getOutput(), getEnergyItem() — содержимое слотов; getEnergyUsage() — J за тик; getRecipeProgress(), getTicksRequired().
- Фабрики: getRecipeProgress(процесс), getInput(процесс), getOutput(процесс), isAutoSortEnabled()/setAutoSort(b).
- Баки и цистерны: getStored() → {name, amount}, getCapacity(), getFilledPercentage(), getNeeded(); химический бак — getDumpingMode()/setDumpingMode("IDLE"|"DUMPING_EXCESS"|"DUMPING").
- Динамический бак ("dynamicValve"): isFormed(), getStored(), getTankCapacity(), getFilledPercentage().

ГЕНЕРАТОРЫ
- getProductionRate() — J за последний тик; getMaxOutput(); плюс энергия (getEnergy…).

ПОДСКАЗКИ
- Методы мультиблоков (матрица, котёл, турбина, реакторы) — через pcall и после isFormed().
- Числа большие: форматируй ("%.2f MFE"):format(fe(x) / 1e6).
- Для общих FE-хранилищ других модов — тип "energy_storage" (lua.peripheral).
