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
  if not f then return nil, "синтаксическая ошибка: " .. tostring(err) end
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

function M.status(jcode)
  local out = {}
  for c, j in pairs(jobs) do
    if not jcode or c == jcode then
      out[#out + 1] = { job = c, target = j.target, name = j.name, state = j.state,
        error = j.last_error, output = j.output and j.output:sub(-600) or nil }
    end
  end
  return out
end

-- Текст для нейросети после ошибки (программа сама инициирует исправление).
function M.fix_prompt(j)
  j.fixes = (j.fixes or 0) + 1
  return string.format(
    "Скрипт «%s» на компьютере #%d завершился ошибкой:\n%s\nПоследний вывод:\n%s\n" ..
    "Исправь программу и вызови script_propose с тем же name и target. Попытка %d из 3.",
    j.name, j.target, tostring(j.last_error), tostring(j.output or ""):sub(-500), j.fixes)
end

return M
