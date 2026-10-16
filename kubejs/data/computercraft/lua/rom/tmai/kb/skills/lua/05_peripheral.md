PERIPHERAL API
- peripheral.getNames() → имена всех доступных периферий: стороны "top", "bottom", "left", "right", "front", "back" и сетевые имена вида "minecraft:chest_3".
- peripheral.getType(имя) → тип(ы) (может быть несколько: "minecraft:chest", "inventory"); peripheral.hasType(имя, "inventory").
- peripheral.wrap(имя) → таблица методов или nil. peripheral.find(тип[, фильтр(имя, обёртка)]) → все подходящие (несколько значений): local a, b = peripheral.find("monitor"); { peripheral.find("inventory") } — списком.
- peripheral.getName(обёртка) → имя; peripheral.getMethods(имя) → список методов (печатай при отладке); peripheral.call(имя, "метод", …).
- Метод вызывается через точку: chest.list(). Отсутствующий метод = nil → «attempt to call a nil value».
- События: peripheral(имя) при подключении, peripheral_detach(имя) при отключении.

СТОРОНЫ И СЕТЬ
- У компьютера стороны относительно его лица; у черепашки front/back/top/bottom — соседние блоки, left/right — её апгрейды (модем, верстак) или соседние блоки, если апгрейд — инструмент.
- Проводная сеть: проводной модем на блоке + сетевой кабель до модема компьютера. Модем блока включают ПКМ (кольцо красное), в чат пишется имя: "minecraft:chest_0". Большой модем (полный блок) обслуживает все стороны.
- Перенос предметов/жидкостей работает только между перифериями, видимыми одному компьютеру одинаково: обе в одной проводной сети или обе вплотную к компьютеру/черепашке.
- Модем-обёртка: modem.getNamesRemote(), modem.getNameLocal() (имя компьютера в сети), modem.isWireless().

ИНВЕНТАРЬ (тип "inventory": сундуки, бочки, машины модов, хранилища)
- inv.size() → число слотов; inv.list() → { [слот] = {name, count, nbt?} } (пустые слоты пропущены — обход pairs).
- inv.getItemDetail(слот) → {name, count, displayName, maxCount, tags = {["c:ingots"] = true}, damage?, maxDamage?, enchantments?…}; inv.getItemLimit(слот).
- inv.pushItems(куда, из_слота[, лимит[, в_слот]]) → сколько перенесено; inv.pullItems(откуда, из_слота[, лимит[, в_слот]]). куда/откуда — имя периферии (строка).
- Каждый вызов — тик сервера: list() раз за проход, getItemDetail — только когда нужны теги/название (кэшируй по name).

```lua
-- переложить всё из входного сундука в выходной (оба в одной проводной сети)
local IN, OUT = "minecraft:chest_0", "minecraft:chest_1"
local src = peripheral.wrap(IN) or error("No inventory " .. IN, 0)
for slot, item in pairs(src.list()) do
  local moved = src.pushItems(OUT, slot)
  if moved < item.count then print("Target full: " .. item.name) end
end
```

ЖИДКОСТИ (тип "fluid_storage": баки, машины)
- tank.tanks() → { {name = "minecraft:water", amount = мB}, … }.
- tank.pushFluid(куда[, лимит_мB[, имя_жидкости]]) → перенесено мB; tank.pullFluid(откуда[, лимит[, имя]]).

ЭНЕРГИЯ (тип "energy_storage": любые хранилища FE, если мод не дал своей периферии)
- es.getEnergy() → FE, es.getEnergyCapacity() → FE. Только чтение.

СВОИ ПЕРИФЕРИИ CC
- monitor — lua.term. modem — lua.rednet. redstone_relay — lua.redstone.
- speaker: playNote(инструмент, громкость 0–3, высота 0–24) — "harp", "bass", "snare", "hat", "basedrum", "bell", "flute", "chime", "guitar", "xylophone", "iron_xylophone", "cow_bell", "didgeridoo", "bit", "banjo", "pling"; playSound("minecraft:block.note_block.pling", громкость, высота); playAudio(буфер_PCM, громкость) → false, если буфер полон (жди событие speaker_audio_empty); stop().
- printer: newPage() → bool, setPageTitle(t), write(text), setCursorPos(x, y), getPageSize(), endPage(), getInkLevel(), getPaperLevel().
- drive: isDiskPresent(), getMountPath(), getDiskLabel(), setDiskLabel(t), hasAudio(), playAudio(), stopAudio(), ejectDisk(), getDiskID().
- computer/turtle рядом или в сети: turnOn(), shutdown(), reboot(), isOn(), getID(), getLabel().
- command (командный блок) в сборке отключён; API commands есть только у командного компьютера — программам ИИ недоступен.
- Карманный компьютер (КПК): API pocket — pocket.equipBack(), pocket.unequipBack() (апгрейд модема/динамика из инвентаря игрока); экран 26×20; работает, пока он в инвентаре игрока.

ОТЛАДКА
Печать всего, что видно: for _, n in ipairs(peripheral.getNames()) do print(n, table.concat({ peripheral.getType(n) }, ",")) end
