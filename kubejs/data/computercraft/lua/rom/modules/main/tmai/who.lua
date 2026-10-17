-- tmai.who — кто говорит у терминала.
-- Терминал CC не сообщает, кто нажимает клавиши, поэтому смотрим, кто стоит ближе всех к детектору игроков
-- (Advanced Peripherals, в капсуле — в полу рубки, отдан в сеть модемом): сужаем радиус, пока в нём
-- не останется один игрок. Нет детектора или рядом никого — последний говоривший (его можно сменить
-- щелчком по имени в строке ввода), иначе единственный игрок онлайн.
-- Вызывать из корутины, которая может уступать управление (методы детектора ждут главный поток сервера).

local M = {}

local det
local online = {}        -- кэш списка игроков онлайн (обновляет M.refresh)
M.manual = nil           -- имя, выбранное вручную щелчком (сильнее детектора до следующей смены)

function M.attach()
  det = peripheral.find("player_detector") or peripheral.find("playerDetector")
  return det ~= nil
end

function M.present() return det ~= nil end

local function in_range(r)
  local ok, list = pcall(det.getPlayersInRange, r)
  if ok and type(list) == "table" then return list end
  return nil
end

-- Ближайший к детектору игрок в радиусе max (по умолчанию 8 блоков) или nil.
function M.nearest(max)
  if not det and not M.attach() then return nil end
  max = max or 8
  local all = in_range(max)
  if not all or #all == 0 then return nil end
  if #all == 1 then return all[1] end
  local lo, hi, best = 1, max, all[1]
  while lo <= hi do                      -- наименьший радиус, где ещё кто-то есть
    local mid = math.floor((lo + hi) / 2)
    local l = in_range(mid)
    if l and #l > 0 then best = l[1]; hi = mid - 1 else lo = mid + 1 end
  end
  return best
end

-- Обновить список игроков онлайн: детектор, иначе функция-запасной вариант (TM-NAV).
function M.refresh(fallback)
  if det or M.attach() then
    local ok, list = pcall(det.getOnlinePlayers)
    if ok and type(list) == "table" then online = list; return online end
  end
  if fallback then
    local list = fallback()
    if type(list) == "table" then online = list end
  end
  return online
end

function M.online() return online end

-- Следующее имя по кругу (щелчок по имени в строке ввода).
function M.cycle(current)
  if #online == 0 then return current end
  for i, n in ipairs(online) do
    if n == current then return online[i % #online + 1] end
  end
  return online[1]
end

-- Кого считать говорящим прямо сейчас (для подсказки в строке ввода и при отправке).
function M.resolve(last)
  if M.manual then return M.manual end
  local n = M.nearest()
  if n then return n end
  if last and last ~= "" then return last end
  if #online >= 1 then return online[1] end
  return "Экипаж"
end

return M
