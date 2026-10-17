-- tmnav.journal — операции штурманского модуля (TM-NAV) для приложения «Журнал» (tmai/apps/journal.lua).
--   journal_scan  { players }          -> { players = { [ник] = { deaths = N, dim = "ns:id" | nil } } }
--     Счёт гибелей — scoreboard «tmj_deaths» (критерий deathCount, заводится сам); измерение — поле игрока
--     Dimension («data get entity <ник> Dimension» -> «DXIII has the following entity data: "minecraft:overworld"»).
--   journal_death { player }           -> { dim, x, y, z } — место последней гибели (LastDeathLocation):
--     «DXIII has the following entity data: {dimension: "minecraft:overworld", pos: [I; 12, 64, -30]}».
--   journal_kills { players, targets } -> { kills = { [ник] = { [id сущности] = N } } }
--     Счёт убийств — scoreboard «tmjb<хэш id>» с критерием minecraft.killed:<ns>.<id> (заводится при первом опросе).
-- Ники — только [A-Za-z0-9_]{3,16} (api.valid_player), id сущностей — только [a-z0-9_.-]:[a-z0-9_.-]; до 8 игроков и
-- 6 целей за запрос (каждая проверка — команда сервера, запрос должен уложиться в таймаут ИИ).

local MAX_PLAYERS, MAX_TARGETS = 8, 6
local DEATHS = "tmj_deaths"

local function entity_ok(id)
  return type(id) == "string" and #id <= 80 and id:match("^[a-z0-9_%.%-]+:[a-z0-9_%.%-]+$") ~= nil
end

local function kill_obj(id)
  local h = 0
  for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000000 end
  return ("tmjb%06d"):format(h)
end

return function(ops, api)
  local made = {}     -- цели, заведённые в этом запуске модуля (повторное «objectives add» безвредно, но лишнее)

  local function objective(name, criterion)
    if made[name] then return end
    api.exec(("scoreboard objectives add %s %s"):format(name, criterion))
    made[name] = true
  end

  local function players_of(p)
    local out, seen = {}, {}
    if type(p.players) ~= "table" then return out end
    for _, n in ipairs(p.players) do
      if api.valid_player(n) and not seen[n] then out[#out + 1] = n; seen[n] = true end
      if #out >= MAX_PLAYERS then break end
    end
    return out
  end

  ops.journal_scan = function(p)
    local list = players_of(p)
    objective(DEATHS, "deathCount")
    local out = {}
    for _, n in ipairs(list) do
      local ok, t = api.exec(("data get entity %s Dimension"):format(n))
      local dim = ok and type(t) == "string" and t:match('"([a-z0-9_%.%-]+:[a-z0-9_%.%-/]+)"') or nil
      out[n] = { deaths = api.score(n, DEATHS), dim = dim }
    end
    return { players = out }
  end

  ops.journal_death = function(p)
    if not api.valid_player(p.player) then return nil, "bad player" end
    local ok, t = api.exec(("data get entity %s LastDeathLocation"):format(p.player))
    if not ok or type(t) ~= "string" then return nil, "нет данных о гибели" end
    local x, y, z = t:match("pos:%s*%[I;%s*(%-?%d+),%s*(%-?%d+),%s*(%-?%d+)%s*%]")
    local dim = t:match('dimension:%s*"([a-z0-9_%.%-]+:[a-z0-9_%.%-/]+)"')
    if not x then return nil, "нет данных о гибели" end
    return { dim = dim, x = tonumber(x), y = tonumber(y), z = tonumber(z) }
  end

  ops.journal_kills = function(p)
    if type(p.targets) ~= "table" then return nil, "bad targets" end
    local list = players_of(p)
    local out = {}
    for _, n in ipairs(list) do out[n] = {} end
    local k = 0
    for _, id in ipairs(p.targets) do
      if k >= MAX_TARGETS then break end
      if entity_ok(id) then
        k = k + 1
        local obj = kill_obj(id)
        objective(obj, "minecraft.killed:" .. (id:gsub(":", ".")))
        for _, n in ipairs(list) do out[n][id] = api.score(n, obj) end
      end
    end
    return { kills = out }
  end
end
