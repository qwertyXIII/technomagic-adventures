-- tmai.netradio — где стоит беспроводной модем, подключённый к проводной сети (для штурманского модуля TM-NAV).
-- ЛОЦМАН пользуется таким модемом как периферией сети «modem_N», а радио ищется вплотную к модулю и компьютеру ИИ —
-- модем на боку проводного модема туда не попадает. Проводной модем CC хранит в своих данных, что к нему подключено:
--   * полноблочный (computercraft:wired_modem_full) — PeripheralType<i> / PeripheralId<i> по граням,
--     i — порядок Direction: 0 низ, 1 верх, 2 север, 3 юг, 4 запад, 5 восток;
--   * кабельный (computercraft:cable) — PeripheralType / PeripheralId, грань — в состоянии блока: modem=<грань>_…
-- Имя периферии в сети — «<PeripheralType>_<PeripheralId>» (номер выдаётся на весь мир). Осматриваем куб вокруг
-- точки одним getBlockInfos (не больше 4096 блоков; порядок — x быстрее всего, потом z, потом y) и проверяем,
-- что на найденном месте правда беспроводной модем.
local M = {}

M.R = 7   -- куб 15×15×15 = 3375 блоков
local WN, WA = "computercraft:wireless_modem_normal", "computercraft:wireless_modem_advanced"
local DIRS = { [0] = { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 }, { -1, 0, 0 }, { 1, 0, 0 } }
local FACE = { down = 0, up = 1, north = 2, south = 3, west = 4, east = 5 }

function M.is_wireless(name) return name == WN or name == WA end

-- Грань проводного модема b, к которой подключена периферия ptype_pid, или nil.
local function face_of(b, ptype, pid)
  if type(b) ~= "table" or type(b.nbt) ~= "table" then return nil end
  if b.name == "computercraft:wired_modem_full" then
    for k = 0, 5 do
      if b.nbt["PeripheralType" .. k] == ptype and tonumber(b.nbt["PeripheralId" .. k]) == pid then return k end
    end
  elseif b.name == "computercraft:cable" and b.nbt.PeripheralType == ptype and tonumber(b.nbt.PeripheralId) == pid then
    local m = type(b.state) == "table" and tostring(b.state.modem or "") or ""
    return FACE[m:match("^(%a+)_") or ""]
  end
end

-- api: info(x, y, z, dim) -> таблица блока | nil; infos(x1, y1, z1, x2, y2, z2, dim) -> список | nil.
-- name — имя периферии в сети («modem_0»), center — {x, y, z}. -> { x, y, z, ender } | nil
function M.find(api, name, center, dim)
  local ptype, pid = tostring(name):match("^(.+)_(%d+)$")
  if not ptype then return nil end
  pid = tonumber(pid)
  local R = M.R
  local blocks = api.infos(center.x - R, center.y - R, center.z - R, center.x + R, center.y + R, center.z + R, dim)
  if type(blocks) ~= "table" then return nil end
  local i = 0
  for dy = -R, R do
    for dz = -R, R do
      for dx = -R, R do
        i = i + 1
        local face = face_of(blocks[i], ptype, pid)
        if face then
          local d = DIRS[face]
          local x, y, z = center.x + dx + d[1], center.y + dy + d[2], center.z + dz + d[3]
          local info = api.info(x, y, z, dim)
          if type(info) == "table" and M.is_wireless(info.name) then
            return { x = x, y = y, z = z, ender = info.name == WA }
          end
        end
      end
    end
  end
end

return M
