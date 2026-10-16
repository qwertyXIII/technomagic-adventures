-- tmai — бортовой ИИ капсулы. Запускается автоматически на компьютере с меткой TM-AI
-- (см. rom/autorun/tmai_boot.lua). Настройка: `set tmai.<параметр> <значение>`,
-- список параметров: `set` или `help tmai`. Состояние и логи: /tmai/.
local args = { ... }
if args[1] == "reset-history" then
  local history = require("tmai.history")
  history.init(); history.clear()
  print("История очищена (сводка и заметки сохранены).")
  return
end
require("tmai.app").run()
