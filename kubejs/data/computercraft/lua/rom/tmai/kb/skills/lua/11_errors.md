ЧИТАТЬ ОШИБКУ: "имя:строка: текст". Имя — файл (/tmai_scripts/name.lua), строка — номер в коде. Стек (stack traceback) показывает цепочку вызовов.

СИНТАКСИС (ловится до запуска)
- "unexpected symbol near …", "'end' expected (to close 'function' at line N)" — лишний/недостающий end, скобка, запятая в таблице.
- "unexpected symbol near '/'" (или '&', '|', '~', '<') — операторы // & | ~ << >> из Lua 5.3: заменить на math.floor(a / b) и bit32.*.
- "'=' expected near …" — опечатка в имени или пропущен local/скобка.
- Строки: кавычки не закрыты; многострочный текст — [[ … ]].

ВЫПОЛНЕНИЕ
- "attempt to index a nil value (local 'mon')" / "(global 'x')" — переменная nil: периферия не найдена (peripheral.find вернул nil), опечатка в имени, функция вернула nil. Проверяй сразу: local mon = peripheral.find("monitor") or error("No monitor", 0).
- "attempt to index a nil value (field 'x')" — в таблице нет поля: структура ответа другая (печатай textutils.serialize(t) при отладке).
- "attempt to call a nil value (field 'getEnergy')" — у периферии нет такого метода: не тот тип или выдуманное имя. Сверь с навыком (lua.ap.*, lua.mekanism…) или peripheral.getMethods(name).
- "attempt to call a nil value (global 'shell')" — в tmexec нет shell/multishell; "(global 'unpack')" — используй table.unpack.
- "attempt to compare number with nil", "attempt to perform arithmetic on a nil value" — значение не пришло (метод вернул nil, err). Проверяй и подставляй 0: local n = x or 0.
- "attempt to compare string with number" — tonumber(s).
- "attempt to concatenate a nil value" — tostring(v) в склейке строк.
- "bad argument #1 to 'x' (number expected, got nil)" — неверный тип аргумента; "expected string, got table" — передан не тот объект.
- "Too long without yielding" — цикл без sleep/событий (lua.events). Добавь sleep(0) / os.queueEvent+pullEvent в тяжёлые циклы, sleep(0.5–5) в циклы опроса.
- "Terminated" — игрок нажал Ctrl+T или «стоп»; не перехватывай её pcall-ом навсегда.
- "No such peripheral" / "Target 'x' does not exist" / "Target 'x' is not an inventory" — неверное имя периферии (сетевые имена смотри peripheral.getNames()) или блок не в той же сети.
- "Out of space" — диск 8 МБ переполнен (логи, большие файлы). "File not found", "Not a directory".
- "Domain not permitted" — HTTP в локальную сеть запрещён.
- "too many results to unpack" — table.unpack огромной таблицы.

ЧЕРЕПАШКА (возвращают false, "причина" — не ошибка, а отказ)
- "Out of fuel" — заправить (lua.turtle, refuel). "Movement obstructed" — блок или моб: dig/attack и повтор.
- "Cannot break unbreakable block" — бедрок/барьер: обойти или закончить. "Cannot break protected block", "Cannot enter protected area" — чужой приват.
- "No tool to dig with" — нет кирки (equipLeft). "Nothing to dig here" — пусто (не ошибка).
- "No items to drop"/"No items to take"/"No items to place" — пустой слот/нет предметов. "No space for items" — инвентарь полон.
- "Too high to move"/"Too low to move" — граница мира.

ADVANCED PERIPHERALS (nil, "КОД")
- "NOT_CONNECTED" — ME-мост не в сети / нет питания. "ITEM_NOT_FOUND", "NOT_CRAFTABLE", "MISSING_ITEMS", "CPU_NOT_FOUND", "NO_VALID_ITEM", "INVENTORY_NOT_FOUND"/"TARGET_NOT_FOUND" (неверное имя куда/откуда).
- Чат-коробка: кулдаун 1 с на сообщение — повтори через sleep(1.1); сообщение длиннее ~1000 байт (кириллица — 2 байта на букву) — дели на части.
- Менеджер инвентаря: «doesn't have a memory card» — вставьте карту памяти, привязанную к игроку.

MEKANISM / МУЛЬТИБЛОКИ
- Ошибка вызова у несобранного мультиблока — сначала isFormed() (Mekanism) / mbIsAssembled() (Extreme Reactors), вызовы — в pcall.
- scram() у уже выключенного реактора и activate() у включённого — ошибка: проверь getStatus().

КАК ИСПРАВЛЯТЬ
1. Найди строку по номеру; 2. пойми, какое значение nil или чего не хватает; 3. исправь причину (проверка, pcall, верный метод), а не только симптом; 4. если причина в мире (нет блока, нет топлива) — понятная ошибка/сообщение для игрока вместо падения.
