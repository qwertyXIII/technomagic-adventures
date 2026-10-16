-- tmai.guard — кто и как часто может обращаться к ЛОЦМАНу + зона радиосвязи.
--
-- Связь устроена «как в МЭ» и повторяет физику радио CC: Tweaked, чтобы чат не обходил механику:
--   * радио ЛОЦМАНа — беспроводной модем на штурманском модуле TM-NAV или на компьютере ИИ (после переезда —
--     там, где их поставили: позицию и модемы TM-NAV измеряет сам); дальность считается формулой CC
--     (modem_range у земли, растёт выше высоты 96 до modem_high_altitude_range у потолка мира);
--   * вышки-ретрансляторы (компьютеры с меткой TM-RELAY…, программа tmrelay) продлевают связь: каждая
--     сообщает капсуле, что жива, а позицию и дальность вышки капсула измерила сама при установке;
--   * эндер-модем (на капсуле или на любой живой вышке) — связь без расстояний и между измерениями.
-- КПК связывается по rednet и подчиняется той же физике сам; для обычного чата программа проверяет,
-- в зоне ли игрок: позицию даёт TM-NAV (data get entity). Вне зоны — «нет связи».

local util = require("tmai.util")
local link = require("tmai.link")

local M = {}

-- держать в синхроне с config/computercraft-server.toml сборки
M.RANGE_LOW, M.RANGE_HIGH = 64, 512
local MAX_Y = { ["minecraft:overworld"] = 319 }

function M.range_at(y, dim)
  local top = MAX_Y[dim] or 255
  if y <= 96 or top <= 96 then return M.RANGE_LOW end
  return math.floor(M.RANGE_LOW + (y - 96) * (M.RANGE_HIGH - M.RANGE_LOW) / (top - 96))
end

local last_ask = {}    -- player -> time
local hour = { start = 0, n = 0 }
local state            -- общий state: state.relays[id] = {x,y,z,dim,range,ender,label}
local alive = {}       -- id -> время последнего маяка

function M.init(st)
  state = st
  state.relays = state.relays or {}
end

function M.relay_beacon(sender)
  if state.relays[sender] then alive[sender] = util.now(); return true end
  return false
end

function M.relay_register(id, info)
  state.relays[id] = info
  alive[id] = util.now()
end

function M.relays()
  local out = {}
  for id, r in pairs(state.relays) do
    out[#out + 1] = { id = id, x = r.x, y = r.y, z = r.z, dim = r.dim, range = r.range, ender = r.ender,
      online = alive[id] ~= nil and util.now() - alive[id] < 180 }
  end
  return out
end

-- Разрешено ли игроку обращаться и не флудит ли он. Возвращает true или false, причина.
function M.allow(cfg, player, text, queue_len)
  if not (cfg.allowed["*"] or cfg.allowed[player]) then return false, "нет доступа" end
  local t = util.now()
  if last_ask[player] and t - last_ask[player] < cfg.player_cooldown then return false, "слишком часто" end
  if queue_len >= cfg.queue_limit then return false, "очередь занята" end
  if t - hour.start > 3600 then hour.start, hour.n = t, 0 end
  if hour.n >= cfg.hourly_limit then return false, "часовой лимит запросов исчерпан" end
  if #text > cfg.max_input * 2 then return false, "слишком длинный вопрос" end
  last_ask[player] = t
  hour.n = hour.n + 1
  return true
end

local function dist2(a, b)
  local dx, dy, dz = a.x - b.x, (a.y or 0) - (b.y or 0), a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

-- Радио ЛОЦМАНа из статуса TM-NAV: список (модем на модуле и/или на компьютере ИИ); старый формат — одно поле radio.
local function radios_of(nav)
  if not nav then return {} end
  if type(nav.radios) == "table" then return nav.radios end
  return nav.radio and { nav.radio } or {}
end

-- Описание связи для контекста ИИ и экрана.
function M.describe(nav)
  local r = radios_of(nav)[1]
  if not r then return "радио ЛОЦМАНа: нет данных (нет беспроводного модема на штурманском модуле или компьютере ИИ)" end
  local s = r.ender and "радио ЛОЦМАНа: эндер-модем (без ограничений)" or ("радио ЛОЦМАНа: беспроводной модем, дальность " .. (r.range or "?") .. " блоков")
  local on, total = 0, 0
  for id, rr in pairs(state.relays) do
    total = total + 1
    if alive[id] and util.now() - alive[id] < 180 then on = on + 1 end
  end
  if total > 0 then s = s .. string.format("; вышек связи: %d (на связи %d)", total, on) end
  return s
end

-- В зоне ли связи игрок. nav = статус TM-NAV { x,y,z,dim, radios={{x,y,z,dim,range,ender},…} }.
function M.in_zone(cfg, player, nav)
  if not cfg.comm_zone then return true, "проверка зоны выключена" end
  local radios = radios_of(nav)
  if #radios == 0 then return true, "нет данных навигации" end  -- не наказываем за сбой модуля
  for _, r in ipairs(radios) do
    if r.ender then return true, "эндер-модем ЛОЦМАНа" end
  end
  for id, rr in pairs(state.relays) do
    if rr.ender and alive[id] and util.now() - alive[id] < 180 then return true, "эндер-вышка #" .. id end
  end
  local p = link.call("pos", { player = player })
  if not p then return true, "позиция неизвестна" end
  for _, r in ipairs(radios) do
    if p.dim == r.dim and dist2(p, r) <= (r.range or M.RANGE_LOW) ^ 2 then return true, "радио ЛОЦМАНа" end
  end
  for id, rr in pairs(state.relays) do
    if alive[id] and util.now() - alive[id] < 180 and rr.dim == p.dim and dist2(p, rr) <= (rr.range or M.RANGE_LOW) ^ 2 then
      return true, "вышка #" .. id
    end
  end
  return false, "вне зоны связи"
end

return M
