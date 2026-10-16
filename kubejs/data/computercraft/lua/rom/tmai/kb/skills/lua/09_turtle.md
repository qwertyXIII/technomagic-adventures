Все функции возвращают true или false, "причина" (кроме getter-ов). Каждое действие занимает тик и уступает управление.

ДВИЖЕНИЕ (1 топливо за блок; повороты бесплатны)
- forward(), back(), up(), down(); turnLeft(), turnRight().
- Отказы: "Movement obstructed" (блок/моб/игрок), "Out of fuel", "Too high to move", "Too low to move", "Cannot leave loaded world", "Cannot enter protected area".
- back() не копает и не видит, что позади: для надёжности развернись и иди forward с копанием.

КОПАНИЕ И АТАКА (нужен инструмент: кирка/топор/лопата/мотыга/меч на сторону)
- dig([сторона]), digUp(), digDown() → true или false: "Nothing to dig here", "Cannot break unbreakable block" (бедрок), "Cannot break block with this tool", "Cannot break protected block", "No tool to dig with". Выпавшее идёт в инвентарь (в выбранный слот, затем в свободные); если места нет — падает на землю.
- attack([сторона]), attackUp(), attackDown() → "Nothing to attack here".
- Гравий/песок падают сверху: после dig() проверяй detect() ещё раз (цикл).

ОСМОТР
- detect(), detectUp(), detectDown() → есть ли блок (не жидкость).
- inspect(), inspectUp(), inspectDown() → true, { name = "minecraft:oak_log", state = {…}, tags = { ["minecraft:logs"] = true } } или false, "No block to inspect".
- compare(), compareUp(), compareDown() — блок совпадает с предметом в выбранном слоте; compareTo(слот) — предметы в слотах одинаковы.

ИНВЕНТАРЬ (16 слотов)
- select(слот), getSelectedSlot(), getItemCount([слот]), getItemSpace([слот]).
- getItemDetail([слот][, подробно]) → nil или { name, count } (с подробно = true ещё displayName, tags, maxCount, damage…).
- transferTo(слот[, кол-во]); drop/dropUp/dropDown([кол-во]) — в инвентарь перед/над/под ней (сундук) или на землю ("No items to drop"); suck/suckUp/suckDown([кол-во]) → "No items to take".
- place/placeUp/placeDown([текст_таблички]) → "Cannot place block here", "No items to place", "Cannot place item here". place() семенами/саженцем/костной мукой — «использовать» на блоке.
- Событие turtle_inventory — инвентарь изменился (ждать, пока игрок подложит топливо).

ТОПЛИВО (в сборке нужно; максимум 20 000 у обычной, 100 000 у продвинутой)
- getFuelLevel() → число или "unlimited"; getFuelLimit().
- refuel([n]) — сжечь n предметов из выбранного слота: "Items not combustible", "No items to combust". refuel(0) — только проверить, топливо ли это.
- Уголь/древесный уголь 80, блок угля 800, доска 15, бревно 15, ведро лавы 1000, палка 5.
- Правило: перед работой и перед каждым удалением держи fuel ≥ расстояние до дома + запас.

ИНСТРУМЕНТЫ И АПГРЕЙДЫ
- equipLeft(), equipRight() — поставить предмет из выбранного слота в апгрейд (старый возвращается в слот). getEquippedLeft(), getEquippedRight() → описание или nil.
- Апгрейды CC: алмазные кирка, топор, лопата, мотыга, меч; верстак (turtle.craft([n]) → "No matching recipes"); беспроводной/эндер-модем; колонка.
- Апгрейды Advanced Peripherals: chat_box, player_detector, environment_detector, geo_scanner, контроллер чанков (держит чанк черепашки загруженным), compass (getFacing), ядра автоматов (lua.ap.sensors). Апгрейд-периферия видна как peripheral "left"/"right".
- Черепашка «видит» соседние блоки как периферию: peripheral.hasType("front", "inventory") — перед ней сундук. Стороны считаются от того, куда она смотрит СЕЙЧАС: после разворота сундук, бывший "back", становится "front".

ПРОЧЕЕ
- Черепашка в выгруженном чанке останавливается, при загрузке включается заново (переменные потеряны) → прогресс в файле, контроллер чанков или FTB Chunks.
- Защищённые чанки FTB Chunks чужой команды черепашка не копает ("Cannot break protected block").
- Запас места: 16 слотов по 64; лишнее (булыжник, земля) можно выбрасывать только если игрок просил (dropDown в лаву/мусорку — опасно, по настройке).
- Готовые приёмы (координаты, безопасное движение, возврат, выгрузка) — lua.turtle_nav; примеры — lua.ex.mine, lua.ex.treefarm.
