Проверенный пример (офлайн-тест: сервер и клиент обмениваются сообщениями). Один файл, роль — настройкой: на компьютере у двери ROLE = "server" (редстоун на сторону SIDE), на пульте (компьютер/карманный компьютер с модемом) ROLE = "client" — клавиши O/C/T/S/Q. Запрос с номером → ответ с тем же номером; клиент повторяет до 3 раз; сервер принимает только команды из списка и, если задан белый список, только от своих id.

```lua
-- ===== настройки =====
local ROLE = "server"            -- "server" (у двери) или "client" (пульт)
local PROTO = "tm_door_v1"       -- своё имя протокола (не "tmai_*")
local HOST = "door1"             -- имя сервера в сети
local SIDE = "back"              -- сервер: сторона редстоуна к двери/лампе
local ALLOWED = nil              -- сервер: { [12] = true } — только эти id; nil — все
local TIMEOUT, TRIES = 2, 3      -- клиент: ожидание ответа и число попыток

if not rednet.isOpen() then peripheral.find("modem", rednet.open) end
if not rednet.isOpen() then error("No modem attached", 0) end

-- ===== сервер =====
local function server()
  local state = redstone.getOutput(SIDE)
  rednet.host(PROTO, HOST)
  print(("Server %s (id %d) on %s"):format(HOST, os.getComputerID(), PROTO))
  while true do
    local id, msg = rednet.receive(PROTO)
    local reply
    if ALLOWED and not ALLOWED[id] then
      reply = { ok = false, err = "denied" }
    elseif type(msg) ~= "table" or type(msg.n) ~= "number" then
      reply = nil                          -- мусор — молча игнорируем
    elseif msg.cmd == "open" then state = true
    elseif msg.cmd == "close" then state = false
    elseif msg.cmd == "toggle" then state = not state
    elseif msg.cmd ~= "status" then reply = { ok = false, err = "unknown command" }
    end
    if type(msg) == "table" and type(msg.n) == "number" then
      redstone.setOutput(SIDE, state)
      reply = reply or { ok = true, state = state }
      reply.n = msg.n
      rednet.send(id, reply, PROTO)
      print(("#%d %s -> %s"):format(id, tostring(msg.cmd), state and "ON" or "OFF"))
    end
  end
end

-- ===== клиент =====
local function request(server, cmd)
  local n = math.random(1, 2 ^ 30)
  for try = 1, TRIES do
    rednet.send(server, { cmd = cmd, n = n }, PROTO)
    local deadline = os.clock() + TIMEOUT
    while os.clock() < deadline do
      local id, msg = rednet.receive(PROTO, deadline - os.clock())
      if id == server and type(msg) == "table" and msg.n == n then return msg end
    end
    print("No reply, retry " .. try)
  end
  return nil
end

local function client()
  local server = rednet.lookup(PROTO, HOST)
  if not server then error("Server '" .. HOST .. "' not found (is it running?)", 0) end
  print("Connected to " .. HOST .. " #" .. server)
  print("Keys: O open, C close, T toggle, S status, Q quit")
  local keymap = { o = "open", c = "close", t = "toggle", s = "status" }
  while true do
    local _, ch = os.pullEvent("char")
    ch = ch:lower()
    if ch == "q" then return end
    local cmd = keymap[ch]
    if cmd then
      local r = request(server, cmd)
      if not r then print("Server does not answer")
      elseif r.ok then print("Door is " .. (r.state and "OPEN" or "CLOSED"))
      else print("Error: " .. tostring(r.err)) end
    end
  end
end

if ROLE == "server" then server() else client() end
```

ПОЯСНЕНИЯ
- Запускать надо оба: сервер — на компьютере у двери, клиент — на пульте (через tmexec — две программы на двух целях с разным ROLE).
- Клавиши клиент получает, когда игрок открыл экран пульта и нажимает их.
- Номер запроса n защищает от путаницы с чужими/старыми ответами; повтор — от потерь вне зоны связи.
- rednet.lookup находит сервер по имени, если он в зоне связи (беспроводной модем ~64 блока у земли, эндер-модем — везде).
