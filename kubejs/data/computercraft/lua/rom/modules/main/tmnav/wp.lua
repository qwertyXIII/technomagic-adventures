-- tmnav.wp — операции штурманского модуля (TM-NAV) для приложения «Метки» (tmai/apps/wp.lua).
--   wp_deaths { players? } -> { deaths = { {player, x, y, z, dim}, … } }
--     Последняя смерть игроков онлайн: ванильное поле игрока LastDeathLocation. Команда
--     «data get entity <ник> LastDeathLocation» отвечает так (MC 1.21.1):
--       DXIII has the following entity data: {dimension: "minecraft:overworld", pos: [I; 12, 64, -30]}
--     Игрок ещё не умирал — команда завершается ошибкой, его пропускаем.
--   Ники — только из списка онлайн (встроенная операция players) или переданные и проверенные valid_player:
--   в команду не попадает ничего, кроме [A-Za-z0-9_]{3,16}.

local MAX_PLAYERS = 20

local function parse(text)
  if type(text) ~= "string" then return nil end
  local x, y, z = text:match("pos:%s*%[I;%s*(%-?%d+),%s*(%-?%d+),%s*(%-?%d+)%s*%]")
  local dim = text:match('dimension:%s*"([a-z0-9_%.%-:/]+)"') or text:match("dimension:%s*'([a-z0-9_%.%-:/]+)'")
  if not x or not dim or not dim:find(":", 1, true) then return nil end
  return { x = tonumber(x), y = tonumber(y), z = tonumber(z), dim = dim }
end

return function(ops, api)
  ops.wp_deaths = function(p)
    local names, seen = {}, {}
    local function take(n)
      if api.valid_player(n) and not seen[n] and #names < MAX_PLAYERS then names[#names + 1] = n; seen[n] = true end
    end
    if type(p.players) == "table" then
      for _, n in ipairs(p.players) do take(n) end
    elseif ops.players then
      local r = ops.players()
      for _, n in ipairs(type(r) == "table" and r.names or {}) do take(n) end
    end
    local out = {}
    for _, n in ipairs(names) do
      local ok, text = api.exec(("data get entity %s LastDeathLocation"):format(n))
      local d = ok and parse(text)
      if d then d.player = n; out[#out + 1] = d end
    end
    return { deaths = out }
  end
end
