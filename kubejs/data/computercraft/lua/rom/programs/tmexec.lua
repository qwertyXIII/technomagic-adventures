-- tmexec — агент запуска скриптов ИИ на ЭТОМ компьютере/черепашке.
-- Запустите один раз (`tmexec`); дальше он ждёт команд от компьютера капсулы.
-- Скрипты лежат в /tmai_scripts/, их можно прочитать `edit` до запуска.
-- Отказывается работать на компьютерах ИИ/NAV и на командных компьютерах.
local label = os.getComputerLabel() or ""
if commands or label == "TM-AI" or label == "TM-NAV" then printError("tmexec: здесь запуск запрещён"); return end
local PROTO = "tmai_exec"
for _, n in ipairs(peripheral.getNames()) do if peripheral.hasType(n, "modem") then rednet.open(n) end end
local owner = settings.get("tmexec.owner")
local running -- { job, co, out }
local names = {} -- job -> имя скрипта

local function report(job, state, extra)
  local m = { op = "status", job = job, state = state }
  for k, v in pairs(extra or {}) do m[k] = v end
  if owner then rednet.send(owner, m, PROTO) end
end

local function make_env(buf)
  local env = setmetatable({}, { __index = _G })
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    buf[#buf + 1] = table.concat(parts, " ")
    if #buf > 50 then table.remove(buf, 1) end
    return print(...)
  end
  env.shell, env.multishell = nil, nil -- скрипт не управляет оболочкой
  return env
end

local function start(job, name)
  local path = "/tmai_scripts/" .. name .. ".lua"
  local h = fs.open(path, "r"); if not h then report(job, "error", { error = "нет файла" }); return end
  local code = h.readAll(); h.close()
  local buf = {}
  local fn, err = load(code, "@" .. path, "t", make_env(buf))
  if not fn then report(job, "error", { error = err }); return end
  running = { job = job, out = buf, co = coroutine.create(function()
    local ok, e = xpcall(fn, debug.traceback)
    if not ok then error(e, 0) end
  end), filter = nil }
  report(job, "running")
end

local function stop()
  if running then report(running.job, "stopped"); running = nil end
  for _, s in ipairs(redstone.getSides()) do redstone.setOutput(s, false) end
end

local function step(ev)
  if not running then return end
  if running.filter and running.filter ~= ev[1] and ev[1] ~= "terminate" then return end
  local ok, filt = coroutine.resume(running.co, table.unpack(ev, 1, ev.n or #ev))
  if not ok then
    report(running.job, "error", { error = tostring(filt):sub(1, 1500), output = table.concat(running.out, "\n") })
    running = nil
  elseif coroutine.status(running.co) == "dead" then
    report(running.job, "done", { output = table.concat(running.out, "\n") })
    running = nil
  else
    running.filter = filt
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
          local h = fs.open("/tmai_scripts/" .. m.name .. ".lua", "w"); h.write(m.code); h.close()
          names[m.job] = m.name
          print("Script " .. m.name .. " received (job " .. tostring(m.job) .. "), waiting for confirmation")
          report(m.job, "deployed")
        elseif m.op == "run" and names[m.job] then
          stop(); start(m.job, names[m.job])
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
