OS
- os.getComputerID() — номер; os.getComputerLabel() / os.setComputerLabel("Name") — метка (латиницей).
- os.startTimer, os.cancelTimer, os.setAlarm, os.cancelAlarm, os.queueEvent — см. lua.events.
- os.clock(), os.epoch("utc"), os.time(), os.day(), os.date(формат) — см. lua.lang.
- os.reboot(), os.shutdown() — в программах для tmexec не вызывать (убьёт агента).
- os.version() → "CraftOS 1.9". Глобальные _HOST (версия Minecraft и CC).

FS (пути от корня "/", регистр важен; /rom — только чтение)
- fs.exists(p), fs.isDir(p), fs.list(dir) → имена, fs.makeDir(p), fs.delete(p), fs.move(a, b), fs.copy(a, b) (ошибка, если b существует).
- fs.combine("/data", "x.txt"), fs.getName(p), fs.getDir(p), fs.getSize(p), fs.getFreeSpace("/"), fs.getCapacity("/"), fs.attributes(p) → {size, isDir, created, modified}, fs.find("/logs/*.txt").
- fs.open(p, mode) → handle | nil, ошибка. Режимы: "r", "w" (перезапись), "a" (дописать), "rb"/"wb"/"ab" (байты), "r+"/"w+".
  - чтение: h.readAll(), h.readLine() (nil в конце), h.read(n), h.seek("set", 0)
  - запись: h.write(s), h.writeLine(s), h.flush()
  - ВСЕГДА h.close(), иначе файл не запишется и держит дескриптор (лимит 128 открытых).
- io.lines(p), io.open(p, mode) — обёртка над fs, работает как в Lua.
- Место: 8 МБ на компьютер (все файлы). Лог-файлы обрезай (например, при > 50 КБ переименуй в .old).

СОХРАНЕНИЕ СОСТОЯНИЯ (переживает перезагрузку и выгрузку чанка)
```lua
local STATE_FILE = "/state_myprog.txt"
local function saveState(t)
  local tmp = STATE_FILE .. ".tmp"            -- пишем во временный и переименовываем:
  local h = fs.open(tmp, "w")                 -- при сбое посреди записи старый файл цел
  h.write(textutils.serialize(t)); h.close()
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  fs.move(tmp, STATE_FILE)
end
local function loadState(default)
  if not fs.exists(STATE_FILE) then return default end
  local h = fs.open(STATE_FILE, "r"); local s = h.readAll(); h.close()
  local t = textutils.unserialize(s)
  return type(t) == "table" and t or default
end
```

SETTINGS (настройки компьютера, файл /.settings)
- settings.define("myprog.limit", { description = "...", default = 64, type = "number" })
- settings.get("myprog.limit") → значение или default; settings.set(имя, v); settings.save() — без save не сохранится; settings.unset(имя).
- Игрок меняет в терминале: set myprog.limit 128. Удобно для порогов, которые игрок захочет подстроить.

TEXTUTILS
- serialize(t[, { compact = true }]) / unserialize(s); serializeJSON(t) / unserializeJSON(s[, { parse_null = true }]).
- formatTime(os.time(), true) → "14:05"; tabulate(...), pagedPrint(text) (ждёт клавишу — не для автоматики); urlEncode(s); slowPrint.

АВТОЗАПУСК
- Файл /startup.lua или каталог /startup/ выполняются при включении. Свою программу ИИ ставит через tmexec; автоперезапуск — «tmexec startup» (игрок вводит один раз). Писать startup самому не нужно.
- После выгрузки чанка компьютер/черепашка выключаются; при загрузке — заново включаются, переменные программы теряются: держи прогресс в файле.

ДИСКЕТЫ (дисковод, тип "drive")
- Диск монтируется как /disk (/disk2…): fs.* по этому пути. disk.isPresent(сторона), disk.getMountPath(сторона), disk.eject(сторона), disk.getLabel/setLabel.
