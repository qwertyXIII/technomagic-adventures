Проверено по jar сборки. Если мода нет в списке навыка — у него нет своей CC-периферии; его хранилища видны как общие "inventory", "fluid_storage", "energy_storage" (lua.peripheral).

DRACONIC EVOLUTION 3.1
- Энергоядро — через ПИЛОН энергии (компьютер/модем к пилону), тип "draconic_rf_storage": getEnergyStored(), getMaxEnergyStored(), getTransferPerTick(), getInputPerTick(), getOutputPerTick(), getEnergyStoredInNotation(), getMaxEnergyStoredInNotation() (числа огромные — notation даёт «1.5E12»).
- Флюкс-врата "flux_gate" (жидкостные — "fluid_gate"): getFlow(), setOverrideEnabled(b), getOverrideEnabled(), setFlowOverride(n) (поток при override), setSignalHighFlow(n)/getSignalHighFlow(), setSignalLowFlow(n)/getSignalLowFlow().
- Реактор Draconic — через стабилизатор или инжектор, тип "draconic_reactor": getReactorInfo() → { status, temperature, fieldStrength, maxFieldStrength, energySaturation, maxEnergySaturation, fuelConversion, maxFuelConversion, generationRate, fieldDrainRate, fuelConversionRate, failSafe }; chargeReactor(), activateReactor(), stopReactor(), toggleFailSafe().
- ОПАСНО: реактор Draconic взрывается (огромный кратер). Стандартная защита: держать поле (fieldStrength/maxFieldStrength) ≥ 30–50 % флюкс-вратами входа (setFlowOverride), температуру ≤ 8000, при поле < 20 % или температуре > 8500 — stopReactor(). Авто-управление — только по явной просьбе и с консервативными порогами.

IMMERSIVE ENGINEERING 12.4 (многоблочные машины через их порт/блок)
- Общее у машин: getEnergyStored(), getMaxEnergyStored(), isRunning(), getEnabled()/setEnabled(b) (выключить по команде).
- Дробилка: getQueueSize(), getInputQueueElement(i). Дуговая печь: isRunning(), getSlag(). Буровая (core sample drill): getSampleProgress(), isSamplingFinished(), getVeinNames(), getVeinIntegrities(), getVeinWeights(), getVeinSaturations(), reset(). Экскаватор, ферментер, сквизер, миксер (getFluid, getCapacity, getNumFluids), очистительный завод, бутылировщик, лесопилка — isRunning(). Автоверстак: getAvailableRecipes(), selectRecipe(i), unselectRecipe(), getSelectedRecipe(). Силос: getContents(). Электросчётчик: getAveragePower(). Прожектор: setEnabled(b), turnAroundXZ(…), turnAroundY(…). Катушка Теслы: isActive(), setRSMode(b), setPowerMode(…). Конденсаторы: getEnergyStored()/getMaxEnergyStored().
- Тип периферии смотри peripheral.getType; список методов — peripheral.getMethods (в IE есть имена слотов вида get…Stack).

POWAH (через Advanced Peripherals) — энергоячейки, реактор, генераторы: lua.ap.sensors.

SUPPLEMENTARIES
- Пушка: getYaw()/setYaw(угол), getPitch()/setPitch(угол), getPower()/setPower(n), ignite() — выстрел. Только по просьбе игрока.
- Блок-динамик (speaker block): setMessage(text), getMessage(), setName(n), getName(), setVolume(v), getVolume(), getMode(), setNarrator(режим), activate() — произнести.

CREATE DIESEL GENERATORS
- Химическая турель: getHorizontalRotation()/setHorizontalRotation(n), getVerticalRotation()/setVerticalRotation(n), spray(). Опасна для игроков — только по просьбе.

ПРОЧЕЕ
- EnderIO: даёт bundled-редстоун для CC (redstone.getBundledInput, lua.redstone); своих периферий нет — машины видны как inventory/energy_storage.
- AE2 — только через ME-мост (lua.ap.me). Flux Networks, Industrial Foregoing, Modern Industrialization, Powah-кабели, солнечные панели и т. п. — общие типы inventory/fluid_storage/energy_storage, если блок отдаёт соответствующую возможность.
- Неизвестный блок: for _, n in ipairs(peripheral.getNames()) do print(n, peripheral.getType(n)) end, затем peripheral.getMethods(n) — и работать только с реально существующими методами.
