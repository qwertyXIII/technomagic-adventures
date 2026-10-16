-- tmexec — агент запуска скриптов ИИ на ЭТОМ компьютере/черепашке.
-- Запустите один раз (`tmexec`); дальше он ждёт команд от компьютера капсулы.
--   tmexec startup   — то же + автозапуск агента при включении; после перезагрузки или выгрузки
--                      чанка агент сам продолжит последнюю подтверждённую программу
--   tmexec nostartup — убрать автозапуск
-- Скрипты лежат в /tmai_scripts/, их можно прочитать `edit` до запуска.
-- Среда скрипта: глобальные API CC, require (модули cc.* и файлы из /tmai_scripts), без shell/multishell;
-- print/printError уходят и в отчёт ИИ (последние 50 строк).
-- Отказывается работать на компьютерах ИИ/NAV и на командных компьютерах.
local args = { ... }
local label = os.getComputerLabel() or ""
if commands or label == "TM-AI" or label == "TM-NAV" then printError("tmexec: not allowed on this computer"); return end
local PROTO = "tmai_exec"
local DIR = "/tmai_scripts"
local RUNNING = DIR .. "/.running"        -- какая программа выполняется (для продолжения после перезагрузки)
local STARTUP = "/startup/tmexec.lua"
local MAX_RESUMES = 20                    -- защита от цикла «упал — перезагрузился — снова»

if args[1] == "nostartup" then
  if fs.exists(STARTUP) then fs.delete(STARTUP) end
  print("tmexec: autostart removed")
  return
elseif args[1] == "startup" then
  if fs.exists("/startup") and not fs.isDir("/startup") then
    printError("tmexec: /startup is a file - rename it to /startup.lua first"); return
  end
  fs.makeDir("/startup")
  local h = fs.open(STARTUP, "w")
  h.write('-- LOCMAN script agent autostart (remove: tmexec nostartup)\n' ..
    'if multishell then shell.openTab("tmexec", "resume") else shell.run("tmexec", "resume") end\n')
  h.close()
  print("tmexec: autostart enabled (" .. STARTUP .. ")")
end

if not fs.isDir(DIR) then fs.makeDir(DIR) end
for _, n in ipairs(peripheral.getNames()) do if peripheral.hasType(n, "modem") then rednet.open(n) end end
local owner = settings.get("tmexec.owner")
local running -- { job, co, out, filter }
local names = {} -- job -> имя скрипта
local make_require = require("cc.require").make

local function report(job, state, extra)
  local m = { op = "status", job = job, state = state }
  for k, v in pairs(extra or {}) do m[k] = v end
  if owner then rednet.send(owner, m, PROTO) end
end

local function mark(job, name, n)
  local h = fs.open(RUNNING, "w")
  h.write(textutils.serialize({ job = job, name = name, n = n or 0 }))
  h.close()
end
local function unmark() if fs.exists(RUNNING) then fs.delete(RUNNING) end end

local function make_env(buf)
  local env = setmetatable({}, { __index = _G })
  local function capture(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    buf[#buf + 1] = table.concat(parts, " ")
    if #buf > 50 then table.remove(buf, 1) end
  end
  env.print = function(...) capture(...); return print(...) end
  env.printError = function(...) capture(...); return printError(...) end
  env.shell, env.multishell = nil, nil -- скрипт не управляет оболочкой
  env.require, env.package = make_require(env, DIR)
  return env
end

local function finish(state, extra)
  report(running.job, state, extra)
  running = nil
  unmark()
end

local function step(ev)
  if not running then return end
  if running.filter and running.filter ~= ev[1] and ev[1] ~= "terminate" then return end
  local ok, filt = coroutine.resume(running.co, table.unpack(ev, 1, ev.n or #ev))
  if not ok then
    finish("error", { error = tostring(filt):sub(1, 1500), output = table.concat(running.out, "\n") })
  elseif coroutine.status(running.co) == "dead" then
    finish("done", { output = table.concat(running.out, "\n") })
  else
    running.filter = filt
  end
end

local function start(job, name, resumes)
  local path = DIR .. "/" .. name .. ".lua"
  local h = fs.open(path, "r"); if not h then report(job, "error", { error = "no file " .. path }); unmark(); return end
  local code = h.readAll(); h.close()
  local buf = {}
  local fn, err = load(code, "@" .. path, "t", make_env(buf))
  if not fn then report(job, "error", { error = err }); unmark(); return end
  running = { job = job, out = buf, co = coroutine.create(function()
    local ok, e = xpcall(fn, debug.traceback)
    if not ok then error(e, 0) end
  end), filter = nil }
  mark(job, name, resumes)
  report(job, "running", (resumes or 0) > 0 and { resumed = resumes } or nil)
  step({ n = 0 })                         -- первый шаг сразу, не дожидаясь чужого события
end

local function stop()
  if running then report(running.job, "stopped"); running = nil end
  unmark()
  for _, s in ipairs(redstone.getSides()) do redstone.setOutput(s, false) end
end

-- программа, прерванная перезагрузкой/выгрузкой чанка: продолжаем только при автозапуске
if fs.exists(RUNNING) then
  local h = fs.open(RUNNING, "r"); local r = textutils.unserialize(h.readAll() or ""); h.close()
  if args[1] == "resume" and type(r) == "table" and type(r.name) == "string" and r.name:match("^[a-z0-9_]+$")
    and fs.exists(DIR .. "/" .. r.name .. ".lua") and (r.n or 0) < MAX_RESUMES then
    names[r.job] = r.name
    print("tmexec: resuming " .. r.name .. " (job " .. tostring(r.job) .. ")")
    start(r.job, r.name, (r.n or 0) + 1)
  else
    if type(r) == "table" and r.name then print("tmexec: program " .. tostring(r.name) .. " was interrupted, not resumed") end
    unmark()
  end
end

print("tmexec ready, id " .. os.getComputerID() .. ", owner " .. tostring(owner))
while true do
  rednet.broadcast({ op = "hello", label = label, kind = turtle and "turtle" or "computer" }, PROTO)
  local timer = os.startTimer(60)
  while true do
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "timer" and ev[2] == timer then break end
    if ev[1] == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" then
      local sender, m = ev[2], ev[3]
      if not owner then owner = sender; settings.set("tmexec.owner", sender); settings.save() end
      if sender == owner then
        if m.op == "deploy" and type(m.code) == "string" and type(m.name) == "string" and m.name:match("^[a-z0-9_]+$") then
          local h = fs.open(DIR .. "/" .. m.name .. ".lua", "w"); h.write(m.code); h.close()
          names[m.job] = m.name
          print("Script " .. m.name .. " received (job " .. tostring(m.job) .. "), waiting for confirmation")
          report(m.job, "deployed")
        elseif m.op == "run" and names[m.job] then
          stop(); start(m.job, names[m.job], 0)
        elseif m.op == "stop" then
          stop()
        end
      end
    elseif ev[1] == "terminate" and running then
      stop()
    elseif ev[1] == "terminate" then
      return
    else
      step(ev)
    end
  end
end
