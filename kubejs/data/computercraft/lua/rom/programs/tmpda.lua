-- tmpda — КПК: маленькая ОС для связи с ЛОЦМАНом вдали от капсулы.
-- Карманный компьютер с беспроводным модемом (дальность мала у земли и растёт с высотой; вышки продлевают)
-- или с эндер-модемом (без ограничений, из любых измерений). Всё идёт по rednet (протокол tmai_radio)
-- на компьютер капсулы. Вкладки (Tab / Shift+Tab или щелчок по полосе вкладок):
--   Чат     — вопрос ЛОЦМАНу (Enter), ответы и объявления капсулы; «да 123» — подтвердить, «стоп» — остановить,
--             «exit» — выйти из программы; PgUp/PgDn — листать;
--   Метки   — общие метки экипажа с расстоянием и стороной света от вас, «+ метка здесь»;
--   Почта   — письма вам, прочитать, ответить, написать игроку по нику;
--   Тревоги — тревоги капсулы (энергия, склад…), последние сверху;
--   Склад   — найти предмет на складе базы и выдать его в сундук «Выдача».
-- С апгрейдом «динамик» КПК проигрывает озвучку (если она включена у капсулы) и звенит на объявления.
-- Сменить ник: set tmpda.player <ник>; забыть капсулу: set tmpda.ai_id "". Код вкладок — /rom/modules/main/tmpda.

local text = require("tmai.text")
local input = require("tmai.input")
local core = require("tmpda.core")

local PROTO = core.PROTO

local function open_modems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then rednet.open(name); n = n + 1 end
  end
  return n
end
if open_modems() == 0 and pocket then pcall(pocket.equipBack) end
if open_modems() == 0 then printError(text.cc("В КПК нет модема: соберите его с беспроводным или эндер-модемом.")); return end

local w, h = term.getSize()

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
  term.write(text.cc(s))
end

local function valid(n) return type(n) == "string" and #n >= 3 and #n <= 16 and n:match("^[A-Za-z0-9_]+$") ~= nil end

-- ---------- ник игрока (первый запуск) ----------
local NAME = settings.get("tmpda.player") or ""
if not valid(NAME) then
  NAME = ""
  term.setBackgroundColor(colors.black); term.clear()
  put(1, 1, "КПК: первый запуск", colors.cyan)
  put(1, 3, "Ваш ник в игре:", colors.white)
  put(1, 6, text.fit("Латиница, цифры, _ (3-16)", w), colors.gray)
  local ned = input.new({ term = term, x = 1, y = 4, width = w, prompt = "> ", max = 16, history = false, prompt_fg = colors.yellow })
  ned:draw()
  while NAME == "" do
    local ev = { os.pullEvent() }
    local r, s = ned:handle(table.unpack(ev))
    if r == "submit" then
      s = (s or ""):gsub("[^A-Za-z0-9_]", "")
      if valid(s) then NAME = s else put(1, 5, text.fit("Нужно 3-16 символов", w), colors.orange, colors.black) end
    end
    ned:draw()
  end
  settings.set("tmpda.player", NAME); settings.save()
end

-- ---------- ОС ----------
local K = core.new({
  term = term, name = NAME, ai = tonumber(settings.get("tmpda.ai_id")),
  speaker = peripheral.find("speaker"),
  send = function(id, msg)
    if id then rednet.send(id, msg, PROTO) else rednet.broadcast(msg, PROTO) end
  end,
  set_ai = function(id) settings.set("tmpda.ai_id", id); settings.save() end,
})
K:start()

while true do
  local ev = table.pack(os.pullEvent())
  if ev[1] == "peripheral" then open_modems() end
  local ok, r = pcall(K.handle, K, table.unpack(ev, 1, ev.n))
  if not ok then                       -- ошибка во вкладке не роняет КПК: показать и работать дальше
    if tostring(r):find("Terminated", 1, true) then error(r, 0) end
    pcall(K.flash, K, "Ошибка: " .. tostring(r), colors.red)
    pcall(K.draw, K)
  elseif r == "exit" then
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    term.clear(); term.setCursorPos(1, 1)
    return
  end
end
