-- tmai.scripts — ИИ пишет Lua-скрипты автоматизации и запускает их на ДРУГИХ компьютерах.
-- На целевом компьютере/черепашке игрок один раз запускает `tmexec` (агент из ROM): он
-- объявляет себя по rednet-протоколу "tmai_exec" и ждёт команд от компьютера капсулы.
-- Поток: нейросеть -> script_propose(target, name, code) -> код записывается на цель
-- (/tmai_scripts/<name>.lua, игрок может открыть `edit`) -> игрок пишет «да КОД» ->
-- запуск -> агент шлёт статус/вывод/ошибку -> при ошибке программа сама просит нейросеть
-- исправить (до N итераций, каждый новый вариант снова требует подтверждения, если
-- игрок не написал «да КОД авто»). «стоп» / «стоп КОД» — остановка.
-- Код выполняется только в песочнице CC: Tweaked на целевом компьютере; на компьютере
-- ИИ и на командном компьютере агент не запускается.

local util = require("tmai.util")

local M = {}

M.PROTO = "tmai_exec"
local targets = {}   -- id -> { label, kind, t }
local jobs = {}      -- code -> { target, name, code_text, player, state, auto, fixes, last_error, output }

function M.on_rednet(sender, msg)
  if type(msg) ~= "table" then return nil end
  if msg.op == "hello" then
    targets[sender] = { label = tostring(msg.label or ""), kind = msg.kind or "computer", t = util.now() }
    return nil
  elseif msg.op == "status" and msg.job and jobs[msg.job] then
    local j = jobs[msg.job]
    j.state = msg.state
    j.output = msg.output
    if msg.state == "error" then j.last_error = msg.error end
    return j, msg
  end
  return nil
end

function M.list_targets()
  local out = {}
  for id, t in pairs(targets) do
    if util.now() - t.t < 300 then
      out[#out + 1] = { id = id, label = t.label, kind = t.kind }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- Код без комментариев (strings = false — и без строк): для быстрых проверок.
local function strip(code, keep_strings)
  code = code:gsub("%-%-%[(=*)%[.-%]%1%]", " ")
  if not keep_strings then code = code:gsub("%[(=*)%[.-%]%1%]", '""') end
  local out, i, n = {}, 1, #code
  while i <= n do
    local ch = code:sub(i, i)
    if ch == "-" and code:sub(i + 1, i + 1) == "-" then
      i = code:find("\n", i, true) or n + 1
    elseif ch == '"' or ch == "'" then
      local j = i + 1
      while j <= n do
        local cj = code:sub(j, j)
        if cj == "\\" then j = j + 2 elseif cj == ch or cj == "\n" then break else j = j + 1 end
      end
      out[#out + 1] = keep_strings and code:sub(i, j) or '""'
      i = j + 1
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Быстрые проверки кода до записи на цель (типовые ошибки, см. навык lua.rules). nil — всё в порядке.
local function lint(code)
  local plain = strip(code)
  if plain:find("//", 1, true) or plain:find("[&|]") or plain:find("<<", 1, true) or plain:find(">>", 1, true)
    or plain:find("~[^=]") then
    return "операторы Lua 5.3 (//, &, |, ~, <<, >>) в CC: Tweaked (Lua 5.2) не работают: math.floor(a / b), bit32.band/bor/bxor/bnot/lshift/rshift"
  end
  if plain:find("[^%w_]shell%s*%.") or plain:find("^shell%s*%.") or plain:find("multishell%s*%.") then
    return "в tmexec нет shell и multishell: не вызывай shell.run/openTab, пиши всё в одном файле"
  end
  if strip(code, true):find("tmai_", 1, true) then
    return "протоколы и имена tmai_* заняты капсулой: назови свой протокол иначе"
  end
  if plain:find("os%.reboot") or plain:find("os%.shutdown") then
    return "os.reboot/os.shutdown остановят агента tmexec: не используй их"
  end
  if plain:find("while%s+true%s+do") then
    local yields = { "sleep%(", "pullEvent", "receive%(", "startTimer", "turtle%.", "parallel%." }
    local ok = false
    for _, p in ipairs(yields) do if plain:find(p) then ok = true; break end end
    if not ok then
      return "бесконечный цикл без sleep/os.pullEvent: будет «Too long without yielding» и нагрузка на сервер — добавь sleep(…) или ожидание события"
    end
  end
  return nil
end

local function sanitize(name)
  name = tostring(name or "script"):lower():gsub("[^a-z0-9_]", "_"):sub(1, 24)
  if name == "" then name = "script" end
  return name
end

function M.propose(args, player)
  local target = tonumber(args.target)
  if not target or not targets[target] then return nil, "неизвестный компьютер; список — computers_list" end
  if target == os.getComputerID() then return nil, "нельзя запускать на компьютере ИИ" end
  local code = tostring(args.code or "")
  if #code == 0 or #code > 16000 then return nil, "код пустой или длиннее 16000 байт" end
  local f, err = load(code, "=" .. sanitize(args.name), "t", {})
  if not f then return nil, "синтаксическая ошибка: " .. tostring(err) .. " (Lua 5.2: нет //, &, |, ~, <<, >> — см. lua.lang)" end
  local why = lint(code)
  if why then return nil, why .. ". Исправь и вызови script_propose снова." end
  -- переиспользуем код задания, если это исправление того же скрипта на той же цели
  local jcode
  for c, j in pairs(jobs) do
    if j.target == target and j.name == sanitize(args.name) then jcode = c end
  end
  jcode = jcode or string.format("%03d", math.random(100, 999))
  local j = jobs[jcode] or { fixes = 0 }
  j.target, j.name, j.code_text, j.player = target, sanitize(args.name), code, player
  j.description = tostring(args.description or "")
  j.state = "proposed"
  jobs[jcode] = j
  rednet.send(target, { op = "deploy", job = jcode, name = j.name, code = code }, M.PROTO)
  if j.auto and j.fixes <= 3 then
    rednet.send(target, { op = "run", job = jcode }, M.PROTO)
    j.state = "starting"
    return { status = "auto_restarted", job = jcode }
  end
  return { status = "awaiting_confirmation", job = jcode,
    say = string.format("Скрипт %s записан на компьютер #%d (/tmai_scripts/%s.lua). Для запуска игрок пишет «да %s» (или «да %s авто» — разрешить до 3 автоисправлений).",
      j.name, target, j.name, jcode, jcode) }
end

function M.confirm(jcode, auto)
  local j = jobs[jcode]
  if not j then return nil end
  j.auto = auto and true or false
  rednet.send(j.target, { op = "run", job = jcode }, M.PROTO)
  j.state = "starting"
  return j
end

function M.stop(jcode)
  local n = 0
  for c, j in pairs(jobs) do
    if not jcode or c == jcode then
      rednet.send(j.target, { op = "stop", job = c }, M.PROTO)
      j.state = "stopped"; j.auto = false
      n = n + 1
    end
  end
  return n
end

function M.is_job(code) return jobs[code] ~= nil end

-- код программы для исправления (без него модель «чинит» вслепую)
local function code_for_fix(j, max)
  local code = tostring(j.code_text or "")
  if #code > max then code = code:sub(1, max) .. "\n-- ...(обрезано)" end
  return code
end

function M.status(jcode)
  local out, errors = {}, 0
  for c, j in pairs(jobs) do
    if (not jcode or c == jcode) and j.state == "error" then errors = errors + 1 end
  end
  for c, j in pairs(jobs) do
    if not jcode or c == jcode then
      local row = { job = c, target = j.target, name = j.name, state = j.state, description = j.description,
        error = j.last_error, output = j.output and j.output:sub(-600) or nil }
      -- упавшая программа: отдать её код, чтобы исправить, а не переписать заново
      if j.state == "error" and (jcode or errors == 1) then row.code = code_for_fix(j, 6000) end
      out[#out + 1] = row
    end
  end
  return out
end

-- Текст для нейросети после ошибки (программа сама инициирует исправление).
function M.fix_prompt(j)
  j.fixes = (j.fixes or 0) + 1
  return string.format(
    "Скрипт «%s» на компьютере #%d (%s) завершился ошибкой:\n%s\nПоследний вывод:\n%s\nКод программы:\n%s\n" ..
    "Сохрани назначение, настройки и поведение программы — исправь только причину ошибки. " ..
    "Найди причину (раздел навыка lua.errors, методы периферии — в lua.* через kb_read), исправь программу " ..
    "и вызови script_propose с тем же name и target. Попытка %d из 3.",
    j.name, j.target, (j.description or "") ~= "" and j.description or "без описания", tostring(j.last_error),
    tostring(j.output or ""):sub(-500), code_for_fix(j, 8000), j.fixes)
end

return M
