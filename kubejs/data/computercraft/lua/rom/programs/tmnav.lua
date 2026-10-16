-- tmnav — штурманский модуль капсулы (КОМАНДНЫЙ компьютер, метка TM-NAV, неразрушим).
-- Единственное место, где выполняются команды сервера, и только из белого списка операций:
--   status      — позиция модуля, уровень ремонта ядра (#tm tm_ai_repair), радио капсулы (модем рядом, эндер ли он);
--   players     — кто онлайн;  pos — координаты и измерение игрока (data get entity);
--   scout_list / locate — поиск мест из /rom/tmai/scout.tsv (уровень ремонта, точность, перезарядка);
--   reward      — награда за поручение из /rom/tmai/rewards.tsv (один раз на поручение);
--   kill_track / kill_count — счёт убийств через scoreboard;
--   relay_probe — найти вышку-ретранслятор рядом с игроком (по ID её компьютера) и измерить её радио.
-- Запросы принимаются только с ПРОВОДНОГО модема (поле side события; distance у проводных сообщений —
-- длина кабеля, не nil) на канале 7300 и только от спаренного компьютера ИИ. Нейросеть сюда не имеет доступа:
-- ИИ (TM-AI) передаёт лишь имя операции и проверенные параметры, всё остальное проверяется здесь ещё раз.
-- Параллельно работает стандартный rednet-`repeat`: мост между радио (КПК, вышки) и проводной сетью рубки.
-- Командные компьютеры работают в одиночной/LAN-игре; на выделенном сервере нужен enable-command-block=true.

if not commands then printError("tmnav: нужен командный компьютер"); return end

local util = require("tmai.util")

local CH = 7300
local STATE = "/tmnav/state.json"
local st = util.load_json(STATE, { ai = nil, rewarded = {}, cooldown = {} })
local function save() util.save_json(STATE, st) end

local scout, scout_by = {}, {}
for _, r in ipairs(util.read_tsv(util.ROM_DIR .. "/scout.tsv")) do
  r.min_repair = tonumber(r.min_repair) or 0
  r.exact_repair = tonumber(r.exact_repair) or 99
  r.cooldown = tonumber(r.cooldown) or 300
  scout[#scout + 1] = r; scout_by[r.id] = r
end
local rewards = {}
for _, r in ipairs(util.read_tsv(util.ROM_DIR .. "/rewards.tsv")) do rewards[r.id] = r end

local function exec(cmd)
  local pok, ok, out = pcall(commands.exec, cmd)
  if not pok then util.log("W", "commands disabled? %s", tostring(ok)); return false, tostring(ok) end
  local text = type(out) == "table" and table.concat(out, "\n") or tostring(out or "")
  util.log("D", "cmd %s -> %s %s", cmd, tostring(ok), text:sub(1, 160))
  return ok, text
end

local function valid_player(name) return type(name) == "string" and name:match("^[%w_]+$") ~= nil and #name >= 3 and #name <= 16 end
local function valid_id(id) return type(id) == "string" and id:match("^#?[a-z0-9_%.%-]+:[a-z0-9_/%.%-]+$") ~= nil end

local function score(holder, obj)
  local ok, text = exec(("scoreboard players get %s %s"):format(holder, obj))
  if not ok then return 0 end
  return tonumber(text:match("(%-?%d+)[^%d]*$")) or 0
end

local function player_pos(name)
  local ok, text = exec(("data get entity %s Pos"):format(name))
  if not ok then return nil end
  local x, y, z = text:match("%[(%-?[%d%.E%-]+)d, (%-?[%d%.E%-]+)d, (%-?[%d%.E%-]+)d%]")
  if not x then return nil end
  local ok2, dtext = exec(("data get entity %s Dimension"):format(name))
  local dim = ok2 and dtext:match('"([%w_%-%.:/]+)"') or "minecraft:overworld"
  return { x = math.floor(tonumber(x)), y = math.floor(tonumber(y)), z = math.floor(tonumber(z)), dim = dim }
end

-- дальность радио по формуле CC: Tweaked (держать в синхроне с computercraft-server.toml и tmai.guard)
local RANGE_LOW, RANGE_HIGH = 64, 512
local function range_at(y, dim)
  local top = (dim == "minecraft:overworld") and 319 or 255
  if y <= 96 then return RANGE_LOW end
  return math.floor(RANGE_LOW + (y - 96) * (RANGE_HIGH - RANGE_LOW) / (top - 96))
end

local SIDES = { { 0, 1, 0 }, { 0, -1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
-- Радио рядом с блоком (x,y,z): {x,y,z, ender} или nil
local function radio_near(x, y, z, dim)
  local best
  for _, d in ipairs(SIDES) do
    local ok, info = pcall(commands.getBlockInfo, x + d[1], y + d[2], z + d[3], dim)
    if ok and type(info) == "table" and info.name then
      if info.name == "computercraft:wireless_modem_advanced" then
        return { x = x + d[1], y = y + d[2], z = z + d[3], ender = true }
      elseif info.name == "computercraft:wireless_modem_normal" then
        best = best or { x = x + d[1], y = y + d[2], z = z + d[3], ender = false }
      end
    end
  end
  return best
end

local function status()
  local okp, x, y, z = pcall(commands.getBlockPosition)
  if not okp then return { repair = 0 } end
  local dim = commands.getDimension and commands.getDimension() or "minecraft:overworld"
  local r = radio_near(x, y, z)
  local radio
  if r then radio = { x = r.x, y = r.y, z = r.z, dim = dim, ender = r.ender, range = r.ender and nil or range_at(r.y, dim) } end
  return { x = x, y = y, z = z, dim = dim, repair = score("#tm", "tm_ai_repair"), radio = radio }
end

local OPS = {}

function OPS.status() return status() end

function OPS.players()
  local names = {}
  local ok, list = pcall(commands.getEntities, "@a")
  if ok and type(list) == "table" then for _, e in ipairs(list) do names[#names + 1] = e.name end end
  return { names = names }
end

function OPS.pos(m)
  if not valid_player(m.player) then return nil, "bad player" end
  local p = player_pos(m.player)
  if not p then return nil, "игрок не найден" end
  return p
end

function OPS.scout_list()
  local lvl = score("#tm", "tm_ai_repair")
  local out = {}
  for _, r in ipairs(scout) do
    if r.min_repair <= lvl then
      local left = math.max(0, (st.cooldown[r.id] or 0) - util.now())
      out[#out + 1] = { id = r.id, name = r.name, dim = r.dim, cooldown_left = math.floor(left), precise = lvl >= r.exact_repair }
    end
  end
  return { repair = lvl, targets = out }
end

local DIRS = { "восток", "юго-восток", "юг", "юго-запад", "запад", "северо-запад", "север", "северо-восток" }

function OPS.locate(m)
  local r = scout_by[m.target]
  if not r then return nil, "цель не из списка" end
  if not valid_player(m.player) then return nil, "bad player" end
  local lvl = score("#tm", "tm_ai_repair")
  if r.min_repair > lvl and not m.free then return nil, "модуль ещё не восстановлен для этой цели" end
  -- перезарядка падает с ремонтом: -15% за ступень
  local cd = math.floor(r.cooldown * math.max(0.4, 1 - 0.15 * lvl))
  if not m.free and (st.cooldown[r.id] or 0) > util.now() then
    return nil, ("перезарядка ещё %d с"):format(math.floor(st.cooldown[r.id] - util.now()))
  end
  local p = player_pos(m.player)
  if not p then return nil, "игрок не найден" end
  if r.dim ~= "" and r.dim ~= p.dim then return nil, "эта цель ищется только в измерении " .. r.dim end
  local what = (r.kind == "biome") and "biome" or "structure"
  local ok, text = exec(("execute in %s positioned %d %d %d run locate %s %s"):format(p.dim, p.x, p.y, p.z, what, r.target))
  if not m.free then st.cooldown[r.id] = util.now() + cd; save() end
  if not ok then return { found = false, name = r.name } end
  local x, z = text:match("%[(%-?%d+), [^,]+, (%-?%d+)%]")
  if not x then return { found = false, name = r.name } end
  x, z = tonumber(x), tonumber(z)
  local dx, dz = x - p.x, z - p.z
  local res = { found = true, name = r.name, dim = p.dim, distance = math.floor(math.sqrt(dx * dx + dz * dz)) }
  if lvl >= r.exact_repair or m.free then
    res.x, res.z = x, z
  else
    local ang = math.deg(math.atan2 and math.atan2(dz, dx) or math.atan(dz, dx))   -- Cobalt (Lua 5.2): atan2
    res.direction = DIRS[(math.floor((ang + 22.5) / 45) % 8) + 1]
    res.distance = math.floor(res.distance / 100 + 0.5) * 100
    res.note = "точные координаты — после ремонта ядра"
  end
  return res
end

function OPS.reward(m)
  local r = rewards[m.reward]
  if not r then return nil, "нет такой награды" end
  if not valid_player(m.player) then return nil, "bad player" end
  if type(m.quest) ~= "string" or st.rewarded[m.quest .. "@" .. m.player] then return nil, "награда за это поручение уже выдана" end
  if not valid_id(r.item) then return nil, "ошибка таблицы наград" end
  local comp = (r.components ~= "" and ("[" .. r.components .. "]")) or ""
  local ok = exec(("give %s %s%s %d"):format(m.player, r.item, comp, tonumber(r.count) or 1))
  if not ok then return nil, "выдача не удалась" end
  st.rewarded[m.quest .. "@" .. m.player] = util.now(); save()
  return { desc = r.desc }
end

local function kill_obj(entity)
  local h = 0
  for i = 1, #entity do h = (h * 31 + entity:byte(i)) % 1000000 end
  return ("tmk%06d"):format(h)
end

function OPS.kill_track(m)
  if not valid_id(m.entity) or not valid_player(m.player) then return nil, "bad args" end
  local obj = kill_obj(m.entity)
  exec(("scoreboard objectives add %s minecraft.killed:%s"):format(obj, m.entity:gsub(":", ".")))
  return { count = score(m.player, obj) }
end

function OPS.kill_count(m)
  if not valid_id(m.entity) or not valid_player(m.player) then return nil, "bad args" end
  return { count = score(m.player, kill_obj(m.entity)) }
end

-- Вышка: игрок стоит рядом с компьютером-ретранслятором; ищем компьютер с ComputerId == relay в кубе 9×9×9.
function OPS.relay_probe(m)
  if not valid_player(m.player) or type(m.relay) ~= "number" then return nil, "bad args" end
  local p = player_pos(m.player)
  if not p then return nil, "игрок не найден" end
  local ok, blocks = pcall(commands.getBlockInfos, p.x - 4, p.y - 4, p.z - 4, p.x + 4, p.y + 4, p.z + 4, p.dim)
  if not ok or type(blocks) ~= "table" then return nil, "не удалось осмотреть место" end
  local i = 0
  for dy = -4, 4 do for dz = -4, 4 do for dx = -4, 4 do
    i = i + 1
    local b = blocks[i]
    if b and b.name and b.name:match("^computercraft:computer") and type(b.nbt) == "table" and b.nbt.ComputerId == m.relay then
      local x, y, z = p.x + dx, p.y + dy, p.z + dz
      local r = radio_near(x, y, z, p.dim)
      if not r then return nil, "у вышки нет беспроводного модема" end
      return { x = x, y = y, z = z, dim = p.dim, ender = r.ender, range = r.ender and nil or range_at(r.y, p.dim) }
    end
  end end end
  return nil, "вышка не найдена рядом с игроком (подойдите ближе, 4 блока)"
end

-- ---------- сеть ----------
local wired, wired_name
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.hasType(name, "modem") and not peripheral.wrap(name).isWireless() then
    wired, wired_name = peripheral.wrap(name), name
  end
end
if not wired then printError("tmnav: нет проводного модема к компьютеру ИИ"); return end
wired.open(CH)

local cmd_ok = exec("scoreboard objectives add tm_ai_repair dummy")

local function serve()
  while true do
    local _, side, ch, _, msg = os.pullEvent("modem_message")
    if ch == CH and side == wired_name and type(msg) == "table" and msg.from == "ai" and type(msg.op) == "string" then
      if not st.ai then st.ai = msg.ai_id; save() end
      local reply = { from = "nav", re = msg.id }
      if msg.ai_id ~= st.ai then
        reply.ok, reply.error = false, "чужой компьютер"
      elseif OPS[msg.op] then
        local ok, data, err = pcall(OPS[msg.op], msg)
        if ok and data then reply.ok, reply.data = true, data
        else reply.ok, reply.error = false, ok and err or tostring(data) end
      else
        reply.ok, reply.error = false, "операция не разрешена"
      end
      wired.transmit(CH, CH, reply)
    end
  end
end

term.clear(); term.setCursorPos(1, 1)
print("TM-NAV online. AI computer: #" .. tostring(st.ai))
print("Radio bridge: rednet repeat")
if not cmd_ok then
  printError("Server commands unavailable (dedicated server: set enable-command-block=true). Scouting and rewards are off.")
end
parallel.waitForAny(serve, function() shell.run("repeat") end)
