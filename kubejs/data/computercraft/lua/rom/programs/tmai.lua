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
-- Падение программы — в лог на диске (/tmai/log.txt) и на экран, потом перезапуск сам: в multishell вкладка
-- ЛОЦМАНа закрылась бы вместе с сообщением и осталась бы голая оболочка. Три падения за 10 минут — ждём клавишу.
local base = term.current()
local crashes = {}
while true do
  local ok, err = pcall(require("tmai.app").run)
  if ok or tostring(err) == "Terminated" then return end
  pcall(require("tmai.util").log, "E", "crash: %s", tostring(err))
  local now = os.epoch("utc")
  local recent = {}
  for _, t in ipairs(crashes) do if now - t < 600000 then recent[#recent + 1] = t end end
  recent[#recent + 1] = now
  crashes = recent
  local cc = require("tmai.text").cc
  term.redirect(base)
  term.setBackgroundColor(colors.black); term.setTextColor(colors.red); term.clear(); term.setCursorPos(1, 1)
  print(cc("ЛОЦМАН упал: " .. tostring(err)))
  print(cc("Подробно: edit /tmai/log.txt"))
  term.setTextColor(colors.white)
  if #crashes >= 3 then
    print(cc("Падает снова и снова. Любая клавиша — запустить ещё раз."))
    os.pullEvent("key")
    crashes = {}
  else
    print(cc("Перезапуск через 5 секунд..."))
    sleep(5)
  end
  -- заново загрузить модули: состояние упавшего запуска не переносится
  for name in pairs(package and package.loaded or {}) do
    if name == "tmai" or name:sub(1, 5) == "tmai." then package.loaded[name] = nil end
  end
end
