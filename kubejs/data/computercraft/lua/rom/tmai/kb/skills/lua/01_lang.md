CC: Tweaked 1.120.2 = Cobalt 0.9.9: Lua 5.2 с частью 5.3/5.4. Проверено по jar.

ЕСТЬ
- goto / ::метка:: (например continue: goto continue … ::continue::).
- bit32: band, bor, bxor, bnot, lshift, rshift, arshift, btest, extract, replace, lrotate, rrotate.
- utf8: char, codes, codepoint, len, offset, charpattern. string.pack/unpack/packsize.
- table.pack (поле n), table.unpack, table.move, table.create; select("#", ...); rawlen.
- load(текст, имя, "t", env) — компиляция строки; pcall, xpcall(f, debug.traceback); error(msg, уровень).
- math.atan(y, x), math.random(a, b) (генератор Lua 5.4), math.floor/ceil/huge/pi/fmod/modf.
- Метатаблицы: __index, __newindex, __call, __tostring, __eq, __lt, __le, __len, __concat; coroutine.*.
- Устаревшее, но работает: loadstring, setfenv/getfenv (только для Lua-функций).

НЕТ (синтаксическая ошибка или nil)
- Операторы // & | ~ << >> (5.3): деление нацело math.floor(a / b), биты — bit32.
- Подтипы integer/float: все числа double. 10 / 2 = 5, 7 / 2 = 3.5. Индексы и счётчики — math.floor.
- io.popen, os.execute, os.getenv, os.exit, os.remove, os.rename, os.tmpname (файлы — только fs.*), string.dump и бинарные чанки, C-модули, __gc.

ГЛОБАЛЬНЫЕ ФУНКЦИИ CC
- print(...) — с переводом строки; write(text) — без; printError(...) — красным; read([символ_маски], [история]) — ввод строки (ждёт игрока!).
- sleep(сек) — пауза (шаг 0.05 с = 1 тик). os.pullEvent([фильтр]) — ждать событие (lua.events).
- Время: os.clock() — секунды работы компьютера; os.epoch("utc") — мс реального времени; os.epoch("ingame"); os.time() — игровые часы 0–24; os.day() — игровой день; os.date("%H:%M") — реальное время сервера.

СТРОКИ И ЧИСЛА
- Строка — байты: #s — байты; кириллица 2 байта на букву (utf8.len(s) — символы). string.upper/lower меняют только латиницу. Резать UTF-8 по байтам нельзя — полбуквы.
- Форматирование: string.format("%.1f%%", 12.345) → "12.3%"; ("%d"):format(math.floor(x)) (%d требует целое — дробь округляй сам, надёжнее "%.0f"); tostring(1e15) → "1e+15". Большие числа: string.format("%.2fM", x / 1e6).
- tonumber("12") → 12, tonumber("abc") → nil. Сравнение строки с числом — ошибка ("attempt to compare string with number").
- Шаблоны Lua (не regex): %d %a %s %w, ".-" нежадный, "^" и "$" — якоря; спецсимволы ( ) . % + - * ? [ ^ $ экранируются %. Пример: name:match("^minecraft:(.+)$").

ТАБЛИЦЫ
- #t — длина массива без дыр; t[#t + 1] = v — добавить; table.insert(t, 1, v); table.remove(t, i).
- pairs — порядок произвольный; ipairs — 1..до первого nil. Удаляешь при обходе — иди с конца: for i = #t, 1, -1 do.
- table.sort(t, function(a, b) return a.count > b.count end); table.concat(t, ", ").
- Копия — вручную, присваивание копирует ссылку. Ключи-числа и ключи-строки разные: t[1] ≠ t["1"].

ОШИБКИ
- error("text", 0) — без позиции в тексте; error(msg, 2) — с позицией вызывающего. assert(v, "msg").
- local ok, err = pcall(f, a, b) → false, "сообщение". Ошибку периферии ловить pcall(m.method, args) или pcall(function() return m.method(args) end).
- Ошибка "Terminated" — игрок нажал Ctrl+T (событие terminate); не глушить её в pcall, иначе программу не остановить: if err == "Terminated" then error(err, 0) end.

ДАННЫЕ
- textutils.serialize(t) / textutils.unserialize(s) — таблица ↔ текст (без функций и циклов). serialize(t, { compact = true }).
- JSON: textutils.serializeJSON(t) / textutils.unserializeJSON(s) (null → nil; пустой массив — textutils.empty_json_array).
- Модули ROM: require("cc.strings") (wrap, ensure_width, split), require("cc.pretty") (pretty.print(pretty.pretty(t))), require("cc.expect"), require("cc.audio.dfpwm"), require("cc.base64").

СТИЛЬ
- Всё local; функцию объявляй до вызова (или local f заранее). Не называй переменные именами API: turtle, peripheral, term, fs, os, string, table, colors, redstone, rednet.
- Метод через двоеточие: s:sub(1, 3), но периферия вызывается через точку: mon.write("x"), chest.list().
