-- tmai — бортовой ИИ капсулы. Запускается автоматически на компьютере с меткой TM-AI
-- (см. rom/autorun/tmai_boot.lua). Настройка: `set tmai.<параметр> <значение>`,
-- список параметров: `set` или `help tmai`. Состояние и логи: /tmai/.
local args = { ... }
if args[1] == "reset-history" then
  local history = require("tmai.history")
  history.init(); history.clear()
  print(require("tmai.text").cc("История очищена (сводка и заметки сохранены)."))
  return
end
-- падение программы — в лог на диске (/tmai/log.txt) и на экран
local ok, err = pcall(require("tmai.app").run)
if not ok and tostring(err) ~= "Terminated" then
  pcall(require("tmai.util").log, "E", "crash: %s", tostring(err))
  term.setBackgroundColor(colors.black); term.setTextColor(colors.red); term.clear(); term.setCursorPos(1, 1)
  local cc = require("tmai.text").cc
  print(cc("ЛОЦМАН упал: " .. tostring(err)))
  print(cc("Подробно: edit /tmai/log.txt. Перезапуск: reboot"))
end
