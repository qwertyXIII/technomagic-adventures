-- Автозапуск программ капсулы по метке компьютера. ROM-autorun выполняется на КАЖДОМ компьютере при старте,
-- поэтому здесь только проверка метки. Метки — латиницей: кириллицу в метках CC отдаёт как "????".
--   TM-AI       — ЛОЦМАН (продвинутый компьютер в носу капсулы)
--   TM-NAV      — штурманский модуль (командный компьютер)
--   TM-RELAY*   — вышка-ретранслятор
--   TM-BUILD*   — черепашка-строитель (tmbuild; сундук-склад позади неё)
--   …KPK…       — КПК (карманный компьютер; название предмета, например «КПК [KPK]»)
local label = os.getComputerLabel() or ""
local prog
if label == "TM-AI" then prog = "tmai"
elseif label == "TM-NAV" then prog = "tmnav"
elseif label:match("^TM%-RELAY") then prog = "tmrelay"
elseif turtle and label:match("^TM%-BUILD") then prog = "tmbuild"
elseif pocket and label:find("KPK", 1, true) then prog = "tmpda"
end
if prog == "tmai" or prog == "tmnav" then
  -- ROM-autorun идёт раньше startup с дискет: запрещаем запуск чужой программы с дискеты в соседнем (или сетевом)
  -- дисководе на компьютере ИИ (там ключи) и на командном компьютере. Только в памяти, файл settings не меняется.
  settings.set("shell.allow_disk_startup", false)
end
if prog then
  if multishell then
    local id = shell.openTab(prog)
    multishell.setTitle(id, prog)
    multishell.setFocus(id)
  else
    shell.run(prog)
  end
end
