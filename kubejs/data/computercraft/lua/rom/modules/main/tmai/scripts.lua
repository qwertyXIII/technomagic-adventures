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
-- Задания и компьютеры хранятся на диске (переживают перезапуск); вкладка «Программы» (tmai/apps/programs.lua)
-- читает их через jobs/job/targets и управляет через confirm/rerun/stop/forget.

local util = require("tmai.util")

local M = {}

M.PROTO = "tmai_exec"
M.EVENT_PROTO = "tmai_event"   -- события программ <-> ЛОЦМАН («Сценарии»): { name = "lockdown", data = … }
local targets = {}   -- id -> { label, kind, t }
local jobs = {}      -- code -> { target, name, code_text, player, state, auto, fixes, last_error, output, t, changed }

-- ---------- хранение: задания и компьютеры переживают перезапуск ЛОЦМАНа (/tmai/scripts.json) ----------
-- Состояния задания: proposed/deployed — ждёт «да КОД»; starting/running — работает; done; error; stopped.
M.FILE = (util.DATA_DIR or "/tmai") .. "/scripts.json"
M.MAX_JOBS = 16      -- старые завершённые задания вытесняются (код программы занимает место на диске)
local loaded = false

local function can_disk() return type(fs) == "table" and util.load_json ~= nil and util.save_json ~= nil end

local function ensure()
  if loaded then return end
  loaded = true
  if not can_disk() then return end
  local ok, st = pcall(util.load_json, M.FILE, nil)
  if not ok or type(st) ~= "table" then return end
  for c, j in pairs(type(st.jobs) == "table" and st.jobs or {}) do
    if type(c) == "string" and c:match("^%d%d%d$") and type(j) == "table" and tonumber(j.target) and not jobs[c] then
      j.target = tonumber(j.target)
      j.name = tostring(j.name or "script")
      if j.ran == nil and not (j.state == "proposed" or j.state == "deployed") then j.ran = true end
      jobs[c] = j
    end
  end
  for id, t in pairs(type(st.targets) == "table" and st.targets or {}) do
    local n = tonumber(id)
    if n and type(t) == "table" and not targets[n] then
      targets[n] = { label = tostring(t.label or ""), kind = t.kind == "turtle" and "turtle" or "computer", t = tonumber(t.t) or 0 }
    end
  end
end

local function persist()
  if not can_disk() then return end
  local tj = {}
  for id, t in pairs(targets) do tj[tostring(id)] = { label = t.label, kind = t.kind, t = t.t } end
  local ok, err = pcall(util.save_json, M.FILE, { jobs = jobs, targets = tj })
  if not ok and util.log then util.log("W", "scripts save: %s", tostring(err)) end
end

local function now() return util.now and util.now() or 0 end

local ACTIVE = { proposed = true, deployed = true, starting = true, running = true }

-- лишние старые задания (не ждущие и не работающие) — вон
local function prune()
  local n = 0
  for _ in pairs(jobs) do n = n + 1 end
  while n > M.MAX_JOBS do
    local old, ot
    for c, j in pairs(jobs) do
      local t = tonumber(j.changed or j.t) or 0
      if not ACTIVE[j.state] and (not ot or t < ot) then old, ot = c, t end
    end
    if not old then break end
    jobs[old] = nil
    n = n - 1
  end
end

function M.on_rednet(sender, msg)
  if type(msg) ~= "table" then return nil end
  ensure()
  if msg.op == "hello" then
    local old = targets[sender]
    local label, kind = tostring(msg.label or ""), msg.kind or "computer"
    targets[sender] = { label = label, kind = kind, t = util.now() }
    if not old or old.label ~= label or old.kind ~= kind then persist() end
    return nil
  elseif msg.op == "status" and msg.job and jobs[msg.job] then
    local j = jobs[msg.job]
    if targets[sender] then targets[sender].t = now() end
    -- повторная запись перед запуском («да КОД», «снова»): «deployed» не отменяет начатый запуск
    if not (msg.state == "deployed" and j.state == "starting") then j.state = msg.state end
    if msg.output ~= nil or msg.state ~= "deployed" then j.output = msg.output end
    if msg.state == "error" then j.last_error = msg.error end
    j.changed = now()
    persist()
    return j, msg
  end
  return nil
end

-- Кто чем занят: target -> { code, name } работающего задания. Одна программа — один компьютер с tmexec.
local function busy_map()
  local m = {}
  for c, j in pairs(jobs) do
    if j.state == "running" or j.state == "starting" then m[j.target] = { code = c, name = j.name } end
  end
  return m
end
M.busy_map = function() ensure(); return busy_map() end

function M.list_targets()
  ensure()
  local busy = busy_map()
  local out = {}
  for id, t in pairs(targets) do
    if util.now() - t.t < 300 then
      local b = busy[id]
      out[#out + 1] = { id = id, label = t.label, kind = t.kind, free = b == nil,
        busy = b and (b.name .. " (" .. b.code .. ")") or nil }
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
  if (strip(code, true):gsub("tmai_event", "")):find("tmai_", 1, true) then
    return "протоколы и имена tmai_* заняты капсулой (кроме tmai_event — события сценариев, lua.ex.events): назови свой протокол иначе"
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
  ensure()
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
  if not jcode then
    for _ = 1, 50 do
      jcode = string.format("%03d", math.random(100, 999))
      if not jobs[jcode] then break end
    end
  end
  local j = jobs[jcode] or { fixes = 0, t = now() }
  j.target, j.name, j.code_text, j.player = target, sanitize(args.name), code, player
  j.description = tostring(args.description or "")
  j.state = "proposed"
  j.ran = nil            -- новый код: запускать (и из сценариев) — только после подтверждения игрока
  j.changed = now()
  jobs[jcode] = j
  prune()
  rednet.send(target, { op = "deploy", job = jcode, name = j.name, code = code }, M.PROTO)
  if j.auto and j.fixes <= 3 then
    rednet.send(target, { op = "run", job = jcode }, M.PROTO)
    j.state = "starting"
    j.ran = true          -- игрок разрешил автоисправления («да КОД авто»)
    persist()
    return { status = "auto_restarted", job = jcode }
  end
  persist()
  local res = { status = "awaiting_confirmation", job = jcode,
    say = string.format("Скрипт %s записан на компьютер #%d (/tmai_scripts/%s.lua). Для запуска игрок пишет «да %s» (или «да %s авто» — разрешить до 3 автоисправлений).",
      j.name, target, j.name, jcode, jcode) }
  local b = busy_map()[target]
  if b and b.code ~= jcode then   -- одна программа — один компьютер: запуск новой остановит работающую
    res.warning = string.format("на #%d сейчас работает %s (%s): запуск новой её остановит. Скажи игроку и спроси согласия — или пусть поставит ещё компьютер с модемом и «tmexec startup».",
      target, b.name, b.code)
    res.say = res.say .. string.format(" Внимание: запуск остановит работающую там программу %s.", b.name)
  end
  return res
end

function M.confirm(jcode, auto)
  ensure()
  local j = jobs[jcode]
  if not j then return nil end
  j.auto = auto and true or false
  -- код — заново: агент мог перезапуститься и забыть задание (тогда «run» он бы молча пропустил)
  if j.code_text then rednet.send(j.target, { op = "deploy", job = jcode, name = j.name, code = j.code_text }, M.PROTO) end
  rednet.send(j.target, { op = "run", job = jcode }, M.PROTO)
  j.state = "starting"
  j.ran = true
  j.changed = now()
  persist()
  return j
end

-- jcode = nil — все, что ждут или работают (завершённые и упавшие из списка не трогаем: агент по «stop»
-- остановил бы на том компьютере уже другую программу).
function M.stop(jcode)
  ensure()
  local n = 0
  for c, j in pairs(jobs) do
    if c == jcode or (not jcode and ACTIVE[j.state]) then
      if jcode or j.state == "running" or j.state == "starting" then
        rednet.send(j.target, { op = "stop", job = c }, M.PROTO)
      end
      j.state = "stopped"; j.auto = false
      j.changed = now()
      n = n + 1
    end
  end
  if n > 0 then persist() end
  return n
end

function M.is_job(code) ensure(); return jobs[code] ~= nil end

-- ---------- для вкладки «Программы» ----------
-- Запустить снова тот же код на той же цели (автоисправления — как были).
function M.rerun(jcode)
  ensure()
  local j = jobs[jcode]
  if not j then return nil, "нет такой программы" end
  if not j.code_text then return nil, "кода программы нет" end
  return M.confirm(jcode, j.auto)
end

-- Убрать задание из списка (работающее — сперва остановить). Файл на целевом компьютере остаётся.
function M.forget(jcode)
  ensure()
  local j = jobs[jcode]
  if not j then return false end
  if j.state == "running" or j.state == "starting" then
    rednet.send(j.target, { op = "stop", job = jcode }, M.PROTO)
  end
  jobs[jcode] = nil
  persist()
  return true
end

-- Задание по коду («123») или по имени программы (последнее изменённое) -> код, задание | nil.
function M.find_job(what)
  ensure()
  what = tostring(what or "")
  if jobs[what] then return what, jobs[what] end
  local best, bt
  for c, j in pairs(jobs) do
    local t = tonumber(j.changed or j.t) or 0
    if j.name == what and (not bt or t > bt) then best, bt = c, t end
  end
  if best then return best, jobs[best] end
  return nil
end

-- Задание как есть (code_text, output, last_error…) — только читать.
function M.job(jcode) ensure(); return jobs[jcode] end

-- Все задания: копии с полем job, новые сверху.
function M.jobs()
  ensure()
  local out = {}
  for c, j in pairs(jobs) do
    local r = {}
    for k, v in pairs(j) do r[k] = v end
    r.job = c
    out[#out + 1] = r
  end
  table.sort(out, function(a, b)
    local ta, tb = tonumber(a.changed or a.t) or 0, tonumber(b.changed or b.t) or 0
    if ta ~= tb then return ta > tb end
    return a.job < b.job
  end)
  return out
end

-- Все известные компьютеры с агентом, и те, что давно молчат: { id, label, kind, online, seen }.
function M.targets()
  ensure()
  local busy = busy_map()
  local out = {}
  for id, t in pairs(targets) do
    local b = busy[id]
    out[#out + 1] = { id = id, label = t.label, kind = t.kind, online = now() - (t.t or 0) < 300, seen = t.t,
      busy = b and b.name or nil, busy_job = b and b.code or nil }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- код программы для исправления (без него модель «чинит» вслепую)
local function code_for_fix(j, max)
  local code = tostring(j.code_text or "")
  if #code > max then code = code:sub(1, max) .. "\n-- ...(обрезано)" end
  return code
end

function M.status(jcode)
  ensure()
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
